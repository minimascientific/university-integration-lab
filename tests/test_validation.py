"""Pure validation tests: no database, no HTTP."""

import copy

import pytest

from integration_lab.mock_portal import PROGRAM_CODES, generate_applications
from integration_lab.validation import ReasonCode, validate_batch

PROGRAMS = set(PROGRAM_CODES)


def _break(mutate):
    record = copy.deepcopy(generate_applications(1)[0])
    mutate(record)
    return record


@pytest.mark.parametrize(
    ("mutate", "expected"),
    [
        (
            lambda r: r["applicant"].update(email="not-an-email"),
            ReasonCode.INVALID_FORMAT,
        ),
        (lambda r: r["applicant"].pop("last_name"), ReasonCode.MISSING_REQUIRED_FIELD),
        (
            lambda r: r["applicant"].update(first_name="  "),
            ReasonCode.MISSING_REQUIRED_FIELD,
        ),
        (lambda r: r.update(program_code="ASTR-BS"), ReasonCode.UNKNOWN_PROGRAM),
        (lambda r: r.update(status="pending"), ReasonCode.INVALID_STATUS),
        (
            lambda r: r["applicant"].update(date_of_birth="2031-05-01"),
            ReasonCode.INVALID_FORMAT,
        ),
        (lambda r: r.update(entry_term="Fall 2027"), ReasonCode.INVALID_FORMAT),
    ],
    ids=[
        "bad_email",
        "missing_last_name",
        "blank_first_name",
        "unknown_program",
        "bad_status",
        "future_birth_date",
        "bad_term",
    ],
)
def test_invalid_record_gets_reason_code(mutate, expected):
    clean, rejected = validate_batch([(1, _break(mutate))], PROGRAMS)
    assert clean == []
    assert [r.reason_code for r in rejected] == [expected]


def test_in_batch_duplicates_keep_newest_version():
    original = generate_applications(1)[0]
    newer = copy.deepcopy(original)
    newer["status"] = "withdrawn"
    newer["decided_at"] = None
    newer["updated_at"] = "2026-12-01T00:00:00+00:00"
    exact_copy = copy.deepcopy(original)

    clean, rejected = validate_batch(
        [(1, original), (2, newer), (3, exact_copy)], PROGRAMS
    )

    assert [(key, rec.status) for key, rec in clean] == [(2, "withdrawn")]
    assert sorted(r.key for r in rejected) == [1, 3]
    assert {r.reason_code for r in rejected} == {ReasonCode.DUPLICATE_IN_BATCH}
