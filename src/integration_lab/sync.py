"""Run one integration: portal API -> staging -> validation -> admissions.*

    uv run lab-sync --scenario normal|duplicates|invalid|error [--limit N]

Steps, each logged with the run id:
  1. Insert an integration_run row (committed at once, so even a crash leaves a trace).
  2. Fetch records from the portal (retries; PortalUnavailable -> run 'failed').
  3. Insert every raw record into staging (committed: the evidence is kept).
  4. In ONE transaction: quarantine rejects found by validation, then
     promote the rest with db/queries/promote_staging_batch.sql.
     If that statement fails, roll back and retry row by row, each record in
     a SAVEPOINT, so a single bad record is quarantined instead of failing all.
  5. Finish the run: counts, status (succeeded / partial / failed), finished_at.
"""

import argparse
import hashlib
import json
import logging

import psycopg
from psycopg.types.json import Jsonb

from integration_lab import db
from integration_lab.portal_client import PortalUnavailable, fetch_applications
from integration_lab.validation import (
    ApplicationIn,
    ReasonCode,
    Rejected,
    validate_batch,
)

log = logging.getLogger("integration_lab.sync")


class RunLog(logging.LoggerAdapter):
    def process(self, msg, kwargs):
        return f"[run {self.extra['run_id']}] {msg}", kwargs


def payload_hash(payload: dict) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def start_run(conn: psycopg.Connection) -> int:
    row = conn.execute(
        "INSERT INTO integration.integration_run DEFAULT VALUES RETURNING run_id"
    ).fetchone()
    return row["run_id"]


def finish_run(
    conn, run_id: int, status: str, error_message: str | None = None, **counts
):
    assignments = ", ".join(f"{name} = %({name})s" for name in counts)
    conn.execute(
        f"""UPDATE integration.integration_run
            SET status = %(status)s, error_message = %(error_message)s,
                finished_at = now(){", " + assignments if assignments else ""}
            WHERE run_id = %(run_id)s""",
        {"run_id": run_id, "status": status, "error_message": error_message, **counts},
    )


def stage_records(conn, run_id: int, records: list[dict]) -> list[tuple[int, dict]]:
    staged = []
    with conn.transaction():
        for record in records:
            row = conn.execute(
                """INSERT INTO integration.staging_application
                       (run_id, portal_application_id, payload, payload_hash)
                   VALUES (%s, %s, %s, %s) RETURNING staging_id""",
                (
                    run_id,
                    record.get("portal_application_id"),
                    Jsonb(record),
                    payload_hash(record),
                ),
            ).fetchone()
            staged.append((row["staging_id"], record))
    return staged


def quarantine(conn, run_id: int, rejects: list[Rejected]) -> None:
    for r in rejects:
        conn.execute(
            """INSERT INTO integration.quarantine
                   (run_id, staging_id, reason_code, message, payload)
               VALUES (%s, %s, %s, %s, %s)""",
            (run_id, r.key, r.reason_code.value, r.message, Jsonb(r.payload)),
        )


def promote_row_by_row(conn, run_id: int, clean: list[tuple[int, ApplicationIn]], rlog):
    """Fallback: one SAVEPOINT per record; a failing record is quarantined."""
    upsert_applicant = db.load_sql("upsert_applicant")
    upsert_application = db.load_sql("upsert_application")
    counts = {"records_inserted": 0, "records_updated": 0, "records_unchanged": 0}
    rejects: list[Rejected] = []

    for staging_id, rec in clean:
        try:
            with conn.transaction():  # nested -> SAVEPOINT; rolls back only this record
                a = rec.applicant
                conn.execute(
                    upsert_applicant,
                    {
                        "portal_applicant_id": a.portal_applicant_id,
                        "first_name": a.first_name,
                        "last_name": a.last_name,
                        "email": a.email,
                        "date_of_birth": a.date_of_birth,
                        "source_updated_at": rec.updated_at,
                    },
                )
                applicant_id = conn.execute(
                    "SELECT applicant_id FROM admissions.applicant WHERE portal_applicant_id = %s",
                    (a.portal_applicant_id,),
                ).fetchone()["applicant_id"]
                row = conn.execute(
                    upsert_application,
                    {
                        "portal_application_id": rec.portal_application_id,
                        "applicant_id": applicant_id,
                        "program_code": rec.program_code,
                        "entry_term": rec.entry_term,
                        "status": rec.status,
                        "submitted_at": rec.submitted_at,
                        "decided_at": rec.decided_at,
                        "source_updated_at": rec.updated_at,
                        "run_id": run_id,
                    },
                ).fetchone()
        except psycopg.errors.IntegrityError as exc:
            rlog.warning(
                "staging_id %s rejected by the database: %s",
                staging_id,
                exc.diag.message_primary,
            )
            rejects.append(
                Rejected(
                    staging_id,
                    rec.model_dump(mode="json"),
                    ReasonCode.CONSTRAINT_VIOLATION,
                    str(exc).strip(),
                )
            )
            continue
        if row is None:
            counts["records_unchanged"] += 1
        elif row["inserted"]:
            counts["records_inserted"] += 1
        else:
            counts["records_updated"] += 1

    quarantine(conn, run_id, rejects)
    conn.execute(
        """UPDATE integration.staging_application SET processed_at = now()
           WHERE run_id = %s AND processed_at IS NULL""",
        (run_id,),
    )
    return counts, len(rejects)


def run_sync(
    base_url: str, scenario: str, limit: int, force_row_by_row: bool = False
) -> int:
    with db.connect() as conn:
        run_id = start_run(conn)
        rlog = RunLog(log, {"run_id": run_id})
        rlog.info("started (scenario=%s, limit=%d)", scenario, limit)
        try:
            records = fetch_applications(
                base_url, scenario=scenario, limit=limit, logger=rlog
            )
            rlog.info("fetched %d records", len(records))

            staged = stage_records(conn, run_id, records)
            rlog.info("staged %d records", len(staged))

            programs = {
                r["program_code"]
                for r in conn.execute(
                    "SELECT program_code FROM admissions.program WHERE is_active"
                )
            }
            clean, rejects = validate_batch(staged, programs)
            for r in rejects:
                rlog.info(
                    "quarantine staging_id %s: %s (%s)",
                    r.key,
                    r.reason_code.value,
                    r.message,
                )

            counts = None
            if not force_row_by_row:
                try:
                    with conn.transaction():
                        quarantine(conn, run_id, rejects)
                        counts = conn.execute(
                            db.load_sql("promote_staging_batch"), {"run_id": run_id}
                        ).fetchone()
                except psycopg.errors.IntegrityError as exc:
                    rlog.warning(
                        "batch promote rolled back (%s); retrying row by row",
                        exc.diag.message_primary,
                    )
            if counts is None:
                with conn.transaction():
                    quarantine(conn, run_id, rejects)
                    counts, db_rejects = promote_row_by_row(conn, run_id, clean, rlog)
                rejects_total = len(rejects) + db_rejects
            else:
                rejects_total = len(rejects)

            status = "partial" if rejects_total else "succeeded"
            finish_run(
                conn,
                run_id,
                status,
                records_fetched=len(records),
                records_staged=len(staged),
                records_quarantined=rejects_total,
                **counts,
            )
            rlog.info(
                "finished %s: inserted=%d updated=%d unchanged=%d quarantined=%d",
                status,
                counts["records_inserted"],
                counts["records_updated"],
                counts["records_unchanged"],
                rejects_total,
            )
        except PortalUnavailable as exc:
            finish_run(conn, run_id, "failed", str(exc))
            rlog.error("failed: portal unavailable: %s", exc)
        except Exception as exc:
            finish_run(conn, run_id, "failed", f"{type(exc).__name__}: {exc}")
            rlog.exception("failed with an unexpected error")
            raise
        return run_id


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Sync applications from the portal API."
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:8001")
    parser.add_argument(
        "--scenario",
        default="normal",
        choices=["normal", "duplicates", "invalid", "error"],
    )
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument(
        "--row-by-row",
        action="store_true",
        help="skip the set-based promote and use the SAVEPOINT fallback",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)-7s %(name)s %(message)s"
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)  # keep lines run-tagged
    run_sync(args.base_url, args.scenario, args.limit, args.row_by_row)


if __name__ == "__main__":
    main()
