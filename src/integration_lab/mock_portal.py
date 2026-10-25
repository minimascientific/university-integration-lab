"""Mock applicant-portal REST API for the fictional Summit Ridge University.

All data is synthetic and deterministic (fixed seed), so every run of the
pipeline sees the same records for the same limit and scenario.

Run:  uv run uvicorn integration_lab.mock_portal:app --port 8001
Try:  curl 'http://127.0.0.1:8001/applications?limit=5&scenario=invalid'
"""

import copy
import random
from datetime import UTC, date, datetime, timedelta
from enum import Enum

from faker import Faker
from fastapi import FastAPI, HTTPException, Query

# Must match db/seed/001_programs.sql
PROGRAM_CODES = ["CSCI-BS", "GEOE-BS", "MECH-BS", "ENVS-BS", "DSCI-MS", "MATS-PHD"]
STATUSES = [
    "submitted",
    "under_review",
    "admitted",
    "denied",
    "waitlisted",
    "withdrawn",
]
DECIDED_STATUSES = {"admitted", "denied", "waitlisted"}
ENTRY_TERMS = ["2027FA", "2027SP"]

SEED = 2027
BASE_TIME = datetime(2026, 9, 1, tzinfo=UTC)  # fixed, so output never drifts
BASE_DATE = BASE_TIME.date()


class Scenario(str, Enum):
    normal = "normal"  # clean records
    duplicates = "duplicates"  # some records repeated within the page
    invalid = "invalid"  # a few records that should be quarantined
    error = "error"  # simulated outage: HTTP 500


app = FastAPI(title="Summit Ridge University Applicant Portal (mock)")


def generate_applications(limit: int) -> list[dict]:
    """Return `limit` clean, deterministic application records."""
    fake = Faker("en_US")
    fake.seed_instance(SEED)
    rng = random.Random(SEED)

    records: list[dict] = []
    applicant: dict | None = None
    applicant_count = 0
    for i in range(1, limit + 1):
        # About 1 in 5 applicants applies to a second program.
        if applicant is None or rng.random() > 0.2:
            applicant_count += 1
            first, last = fake.first_name(), fake.last_name()
            applicant = {
                "portal_applicant_id": f"PA-{applicant_count:05d}",
                "first_name": first,
                "last_name": last,
                "email": f"{first}.{last}{rng.randint(1, 99)}@example.com".lower(),
                "date_of_birth": (
                    BASE_DATE - timedelta(days=rng.randint(17 * 365, 40 * 365))
                ).isoformat(),
            }

        status = rng.choice(STATUSES)
        submitted = BASE_TIME + timedelta(
            days=rng.randint(0, 40), minutes=rng.randint(0, 1439)
        )
        decided = (
            submitted + timedelta(days=rng.randint(5, 30))
            if status in DECIDED_STATUSES
            else None
        )
        updated = (decided or submitted) + timedelta(hours=rng.randint(1, 48))

        records.append(
            {
                "portal_application_id": f"APP-{i:06d}",
                "applicant": dict(applicant),
                "program_code": rng.choice(PROGRAM_CODES),
                "entry_term": rng.choice(ENTRY_TERMS),
                "status": status,
                "submitted_at": submitted.isoformat(),
                "decided_at": decided.isoformat() if decided else None,
                "updated_at": updated.isoformat(),
            }
        )
    return records


def add_duplicates(records: list[dict]) -> list[dict]:
    """Two exact repeats plus one newer revision of an existing record."""
    out = list(records)
    for idx in (2, 5):
        if idx < len(records):
            out.append(copy.deepcopy(records[idx]))
    if len(records) > 7:
        revised = copy.deepcopy(records[7])
        revised["status"] = "withdrawn"
        revised["decided_at"] = None
        revised["updated_at"] = (
            datetime.fromisoformat(revised["updated_at"]) + timedelta(days=1)
        ).isoformat()
        out.append(revised)
    return out


def add_invalid(records: list[dict]) -> list[dict]:
    """Corrupt a few records, one problem each."""
    out = copy.deepcopy(records)
    if len(out) > 1:
        out[1]["applicant"]["email"] = "not-an-email"
    if len(out) > 3:
        del out[3]["applicant"]["last_name"]
    if len(out) > 4:
        out[4]["program_code"] = "ASTR-BS"  # not offered
    if len(out) > 6:
        out[6]["applicant"]["date_of_birth"] = date(2031, 5, 1).isoformat()
    if len(out) > 8:
        out[8]["status"] = "pending"  # not a valid status
    return out


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/applications")
def list_applications(
    limit: int = Query(50, ge=1, le=500),
    scenario: Scenario = Scenario.normal,
) -> dict:
    if scenario is Scenario.error:
        raise HTTPException(status_code=500, detail="Simulated portal outage")

    records = generate_applications(limit)
    if scenario is Scenario.duplicates:
        records = add_duplicates(records)
    elif scenario is Scenario.invalid:
        records = add_invalid(records)
    return {"count": len(records), "applications": records}
