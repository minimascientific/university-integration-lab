"""Validate raw portal records before they are promoted out of staging.

validate_batch() splits a batch into clean records and rejects. Each reject
carries a reason code matching the CHECK list on integration.quarantine.
"""

from dataclasses import dataclass
from datetime import date
from enum import StrEnum
from typing import Literal

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
    model_validator,
)


class ReasonCode(StrEnum):
    MISSING_REQUIRED_FIELD = "missing_required_field"
    INVALID_FORMAT = "invalid_format"
    UNKNOWN_PROGRAM = "unknown_program"
    INVALID_STATUS = "invalid_status"
    DUPLICATE_IN_BATCH = "duplicate_in_batch"
    CONSTRAINT_VIOLATION = "constraint_violation"


class ApplicantIn(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)

    portal_applicant_id: str = Field(min_length=1)
    first_name: str = Field(min_length=1)
    last_name: str = Field(min_length=1)
    email: str = Field(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    date_of_birth: date | None = None

    @field_validator("date_of_birth")
    @classmethod
    def not_in_future(cls, value: date | None) -> date | None:
        if value is not None and value > date.today():
            raise ValueError("date_of_birth is in the future")
        return value


class ApplicationIn(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)

    portal_application_id: str = Field(min_length=1)
    applicant: ApplicantIn
    program_code: str = Field(min_length=1)
    entry_term: str = Field(pattern=r"^[0-9]{4}(FA|SP|SU)$")
    status: Literal[
        "submitted", "under_review", "admitted", "denied", "waitlisted", "withdrawn"
    ]
    submitted_at: AwareDatetime
    decided_at: AwareDatetime | None = None
    updated_at: AwareDatetime

    @model_validator(mode="after")
    def decided_after_submitted(self) -> "ApplicationIn":
        if self.decided_at is not None and self.decided_at < self.submitted_at:
            raise ValueError("decided_at is before submitted_at")
        return self


@dataclass
class Rejected:
    key: int  # staging_id
    payload: dict
    reason_code: ReasonCode
    message: str


def _reason_for(error: ValidationError) -> tuple[ReasonCode, str]:
    errors = error.errors()
    message = "; ".join(
        f"{'.'.join(str(p) for p in e['loc']) or 'record'}: {e['msg']}" for e in errors
    )
    first = errors[0]
    if first["type"] in ("missing", "string_too_short"):
        return ReasonCode.MISSING_REQUIRED_FIELD, message
    if first["loc"] and first["loc"][-1] == "status":
        return ReasonCode.INVALID_STATUS, message
    return ReasonCode.INVALID_FORMAT, message


def validate_batch(
    items: list[tuple[int, dict]], known_program_codes: set[str]
) -> tuple[list[tuple[int, ApplicationIn]], list[Rejected]]:
    """items are (staging_id, payload). Returns (clean, rejected).

    Within a batch, only the newest version (latest updated_at) of each
    portal_application_id is kept; older copies are rejected as duplicates.
    """
    candidates: list[tuple[int, ApplicationIn]] = []
    rejected: list[Rejected] = []

    for key, payload in items:
        try:
            record = ApplicationIn.model_validate(payload)
        except ValidationError as exc:
            reason, message = _reason_for(exc)
            rejected.append(Rejected(key, payload, reason, message))
            continue
        if record.program_code not in known_program_codes:
            rejected.append(
                Rejected(
                    key,
                    payload,
                    ReasonCode.UNKNOWN_PROGRAM,
                    f"program_code {record.program_code!r} is not offered",
                )
            )
            continue
        candidates.append((key, record))

    newest: dict[str, tuple[int, ApplicationIn]] = {}
    for key, record in candidates:
        current = newest.get(record.portal_application_id)
        if current is None or record.updated_at > current[1].updated_at:
            newest[record.portal_application_id] = (key, record)

    clean = []
    for key, record in candidates:
        kept_key = newest[record.portal_application_id][0]
        if key == kept_key:
            clean.append((key, record))
        else:
            rejected.append(
                Rejected(
                    key,
                    record.model_dump(mode="json"),
                    ReasonCode.DUPLICATE_IN_BATCH,
                    f"{record.portal_application_id} appears more than once in this "
                    f"batch; kept staging_id {kept_key}",
                )
            )
    return clean, rejected
