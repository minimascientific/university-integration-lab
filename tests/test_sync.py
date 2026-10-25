"""End-to-end sync runs against the test database, with a mocked portal."""

import copy

import httpx
import psycopg
import pytest

from integration_lab.mock_portal import generate_applications
from integration_lab.sync import run_sync

from .conftest import BASE_URL, fetch_one, portal_transport


def sync(scenario="normal", limit=20, transport=None, **kwargs) -> dict:
    """Run a sync and return its integration_run row."""
    from integration_lab import db

    run_id = run_sync(
        BASE_URL,
        scenario,
        limit,
        transport=transport or portal_transport(),
        backoff_seconds=0,
        **kwargs,
    )
    with db.connect() as c:
        return fetch_one(
            c, "SELECT * FROM integration.integration_run WHERE run_id = %s", (run_id,)
        )


def count(conn, table: str) -> int:
    return fetch_one(conn, f"SELECT count(*) AS n FROM {table}")["n"]


def quarantine_codes(conn, run_id: int) -> list[str]:
    rows = conn.execute(
        "SELECT reason_code FROM integration.quarantine WHERE run_id = %s ORDER BY reason_code",
        (run_id,),
    ).fetchall()
    return [r["reason_code"] for r in rows]


# --- happy path and idempotency ----------------------------------------


def test_normal_run_loads_everything(conn):
    run = sync()
    assert run["status"] == "succeeded"
    assert (
        run["records_fetched"],
        run["records_inserted"],
        run["records_quarantined"],
    ) == (20, 20, 0)
    assert count(conn, "admissions.application") == 20
    assert (
        count(conn, "integration.staging_application WHERE processed_at IS NULL") == 0
    )


def test_rerun_is_idempotent(conn):
    sync()
    before = conn.execute(
        "SELECT portal_application_id, updated_at FROM admissions.application ORDER BY 1"
    ).fetchall()

    run = sync()

    assert (
        run["records_inserted"],
        run["records_updated"],
        run["records_unchanged"],
    ) == (0, 0, 20)
    after = conn.execute(
        "SELECT portal_application_id, updated_at FROM admissions.application ORDER BY 1"
    ).fetchall()
    assert after == before  # same rows, and updated_at not touched


# --- duplicates -------------------------------------------------------------


def test_in_batch_duplicates_are_quarantined_and_newest_wins(conn):
    run = sync("duplicates")

    assert run["status"] == "partial"
    assert quarantine_codes(conn, run["run_id"]) == ["duplicate_in_batch"] * 3
    assert count(conn, "admissions.application") == 20
    # mock_portal adds a newer revision of APP-000008 that withdraws it
    status = fetch_one(
        conn,
        "SELECT status FROM admissions.application "
        "WHERE portal_application_id = 'APP-000008'",
    )["status"]
    assert status == "withdrawn"


def test_newer_record_updates_and_stale_record_is_ignored(conn):
    original = generate_applications(1)[0]
    sync(transport=portal_transport([original]))

    newer = copy.deepcopy(original)
    newer.update(
        status="withdrawn", decided_at=None, updated_at="2026-12-01T00:00:00+00:00"
    )
    run = sync(transport=portal_transport([newer]))
    assert run["records_updated"] == 1

    stale = copy.deepcopy(original)
    stale.update(
        status="under_review", decided_at=None, updated_at="2026-08-01T00:00:00+00:00"
    )
    run = sync(transport=portal_transport([stale]))
    assert (run["records_updated"], run["records_unchanged"]) == (0, 1)

    row = fetch_one(conn, "SELECT status FROM admissions.application")
    assert row["status"] == "withdrawn"


# --- invalid data -----------------------------------------------------------


def test_invalid_records_are_quarantined_and_valid_rows_still_load(conn):
    run = sync("invalid")

    assert run["status"] == "partial"
    assert quarantine_codes(conn, run["run_id"]) == [
        "invalid_format",
        "invalid_format",
        "invalid_status",
        "missing_required_field",
        "unknown_program",
    ]
    assert run["records_inserted"] == 15
    assert count(conn, "admissions.application") == 15
    # quarantined payloads are kept for triage and linked to their staging row
    assert count(conn, "integration.quarantine WHERE staging_id IS NULL") == 0


def test_database_rejection_falls_back_to_row_by_row(conn):
    """A record Pydantic accepts but a DB constraint rejects: the batch statement
    rolls back, the row-by-row SAVEPOINT path quarantines just that record."""
    records = generate_applications(5)
    records[2]["applicant"]["last_name"] = "Rejectme"
    conn.execute(
        "ALTER TABLE admissions.applicant ADD CONSTRAINT test_reject "
        "CHECK (last_name <> 'Rejectme')"
    )
    try:
        run = sync(transport=portal_transport(records))
    finally:
        conn.execute("ALTER TABLE admissions.applicant DROP CONSTRAINT test_reject")

    assert run["status"] == "partial"
    assert quarantine_codes(conn, run["run_id"]) == ["constraint_violation"]
    assert run["records_inserted"] == 4
    assert count(conn, "admissions.application") == 4


# --- API failure ------------------------------------------------------------


def test_portal_500_retries_then_marks_run_failed(conn):
    transport = portal_transport(status=500)
    run = sync(transport=transport)

    assert len(transport.calls) == 4  # first try + 3 retries
    assert run["status"] == "failed"
    assert "HTTP 500" in run["error_message"]
    assert run["finished_at"] is not None
    # nothing partial was written
    assert count(conn, "integration.staging_application") == 0
    assert count(conn, "admissions.application") == 0


def test_portal_unreachable_marks_run_failed(conn):
    import httpx

    def refuse(request):
        raise httpx.ConnectError("connection refused", request=request)

    run = sync(transport=httpx.MockTransport(refuse))

    assert run["status"] == "failed"
    assert "ConnectError" in run["error_message"]
    assert count(conn, "admissions.applicant") == 0


def test_portal_400_is_not_retried(conn):
    transport = portal_transport(status=400)
    with pytest.raises(httpx.HTTPStatusError):
        sync(transport=transport)
    assert len(transport.calls) == 1
    run = fetch_one(
        conn, "SELECT status, error_message FROM integration.integration_run"
    )
    assert run["status"] == "failed"
    assert "400" in run["error_message"]


# --- reporting query --------------------------------------------------------


def test_report_includes_programs_with_no_applications(conn):
    from integration_lab import db

    sync()
    rows = conn.execute(
        db.load_sql("report_applications_by_program_status"), {"entry_term": "2027SU"}
    ).fetchall()  # no records use SU
    assert len(rows) == 6
    assert {r["total"] for r in rows} == {0}


def test_unique_key_blocks_raw_duplicate_insert(conn):
    sync(transport=portal_transport(generate_applications(1)))
    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            "INSERT INTO admissions.application (portal_application_id, applicant_id, "
            "program_id, entry_term, status, submitted_at, source_updated_at) "
            "SELECT portal_application_id, applicant_id, program_id, entry_term, status, "
            "submitted_at, source_updated_at FROM admissions.application"
        )
