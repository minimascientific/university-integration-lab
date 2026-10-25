-- =====================================================================
-- University Application Integration Lab: DRAFT schema
-- Fictional institution ("Summit Ridge University"); all data synthetic.
-- Runs automatically on first `docker compose up` (empty volume only).
-- Lines marked "-- REVIEW:" are design decisions for you to confirm or change.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS admissions;   -- clean, trusted business data
CREATE SCHEMA IF NOT EXISTS integration;  -- pipeline plumbing: runs, staging, quarantine

-- ---------------------------------------------------------------------
-- admissions.program: reference data, loaded from db/seed
-- ---------------------------------------------------------------------
CREATE TABLE admissions.program (
    program_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    program_code  TEXT NOT NULL UNIQUE,          -- e.g. 'CSCI-BS'; what the API sends
    program_name  TEXT NOT NULL,
    degree_level  TEXT NOT NULL CHECK (degree_level IN ('BS', 'MS', 'PHD')),
    is_active     BOOLEAN NOT NULL DEFAULT TRUE
);
-- REVIEW: Surrogate key (program_id) + UNIQUE natural key (program_code).
--         Could program_code alone be the PK? What do you gain or lose?

-- ---------------------------------------------------------------------
-- admissions.applicant: one row per person
-- ---------------------------------------------------------------------
CREATE TABLE admissions.applicant (
    applicant_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portal_applicant_id  TEXT NOT NULL UNIQUE,   -- ID from the source portal API
    first_name           TEXT NOT NULL,
    last_name            TEXT NOT NULL,
    email                TEXT NOT NULL,
    date_of_birth        DATE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT applicant_email_format CHECK (email LIKE '%_@_%')
);
CREATE UNIQUE INDEX applicant_email_lower_uq ON admissions.applicant (lower(email));
-- REVIEW: Which key identifies a person for UPSERT: portal_applicant_id or email?
--         Unique lower(email) blocks two portal IDs sharing one email. Is that a
--         duplicate to quarantine, or legitimate (e.g. a shared family email)?
-- REVIEW: updated_at has no trigger; your UPSERT must set it. Keep it that way?

-- ---------------------------------------------------------------------
-- admissions.application: one row per application to a program/term
-- ---------------------------------------------------------------------
CREATE TABLE admissions.application (
    application_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portal_application_id  TEXT NOT NULL UNIQUE,   -- idempotency key for UPSERT
    applicant_id           BIGINT NOT NULL REFERENCES admissions.applicant (applicant_id)
                               ON DELETE RESTRICT,
    program_id             INTEGER NOT NULL REFERENCES admissions.program (program_id)
                               ON DELETE RESTRICT,
    entry_term             TEXT NOT NULL CHECK (entry_term ~ '^[0-9]{4}(FA|SP|SU)$'),
    status                 TEXT NOT NULL CHECK (status IN
                               ('submitted', 'under_review', 'admitted',
                                'denied', 'waitlisted', 'withdrawn')),
    submitted_at           TIMESTAMPTZ NOT NULL,
    decided_at             TIMESTAMPTZ,
    source_updated_at      TIMESTAMPTZ NOT NULL,   -- portal's last-modified time
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_run_id            BIGINT,                 -- FK added below (integration schema)
    CONSTRAINT application_decided_after_submitted
        CHECK (decided_at IS NULL OR decided_at >= submitted_at)
);
CREATE INDEX application_applicant_idx    ON admissions.application (applicant_id);
CREATE INDEX application_program_term_idx ON admissions.application (program_id, entry_term);
-- REVIEW: ON DELETE RESTRICT vs CASCADE: should deleting an applicant ever
--         silently delete their applications?
-- REVIEW: status as a CHECK list vs a lookup table (admissions.application_status).
--         Which is easier to change mid-cycle? Which gives a nicer error?
-- REVIEW: source_updated_at lets an UPSERT ignore stale/out-of-order records
--         ("only update if incoming is newer"). Do you want that rule?
-- REVIEW: Indexes. Which queries in db/queries/ need them? Is (status) worth one?

-- ---------------------------------------------------------------------
-- integration.integration_run: one row per pipeline execution
-- ---------------------------------------------------------------------
CREATE TABLE integration.integration_run (
    run_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_name          TEXT NOT NULL DEFAULT 'applicant_portal_api',
    started_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at          TIMESTAMPTZ,
    status               TEXT NOT NULL DEFAULT 'running'
                             CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
    records_fetched      INTEGER NOT NULL DEFAULT 0 CHECK (records_fetched >= 0),
    records_staged       INTEGER NOT NULL DEFAULT 0 CHECK (records_staged >= 0),
    records_inserted     INTEGER NOT NULL DEFAULT 0 CHECK (records_inserted >= 0),
    records_updated      INTEGER NOT NULL DEFAULT 0 CHECK (records_updated >= 0),
    records_unchanged    INTEGER NOT NULL DEFAULT 0 CHECK (records_unchanged >= 0),
    records_quarantined  INTEGER NOT NULL DEFAULT 0 CHECK (records_quarantined >= 0),
    error_message        TEXT,                    -- set when status = 'failed'
    CONSTRAINT run_finished_after_started
        CHECK (finished_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX integration_run_started_idx ON integration.integration_run (started_at DESC);

ALTER TABLE admissions.application
    ADD CONSTRAINT application_last_run_fk
    FOREIGN KEY (last_run_id) REFERENCES integration.integration_run (run_id);

-- ---------------------------------------------------------------------
-- integration.staging_application: raw API records, exactly as received
-- ---------------------------------------------------------------------
CREATE TABLE integration.staging_application (
    staging_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id                 BIGINT NOT NULL REFERENCES integration.integration_run (run_id)
                               ON DELETE CASCADE,
    portal_application_id  TEXT,                  -- nullable: raw data may lack it
    payload                JSONB NOT NULL,
    payload_hash           TEXT NOT NULL,         -- e.g. sha256 of canonical JSON
    received_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at           TIMESTAMPTZ            -- NULL = not yet promoted/quarantined
);
CREATE INDEX staging_unprocessed_idx
    ON integration.staging_application (run_id) WHERE processed_at IS NULL;
-- REVIEW: Where does validation live: Python (Pydantic) before promotion, SQL
--         constraints at promotion, or both? Staging is deliberately loose so
--         bad records can land here and be quarantined, not lost.
-- REVIEW: payload_hash can detect "same record, no change" cheaply. Should it be
--         UNIQUE per run (UNIQUE (run_id, payload_hash)) to drop exact duplicates?

-- ---------------------------------------------------------------------
-- integration.quarantine: records that failed validation, kept for triage
-- ---------------------------------------------------------------------
CREATE TABLE integration.quarantine (
    quarantine_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          BIGINT NOT NULL REFERENCES integration.integration_run (run_id),
    staging_id      BIGINT REFERENCES integration.staging_application (staging_id)
                        ON DELETE SET NULL,
    reason_code     TEXT NOT NULL CHECK (reason_code IN
                        ('missing_required_field', 'invalid_format', 'unknown_program',
                         'invalid_status', 'duplicate_in_batch', 'constraint_violation')),
    message         TEXT NOT NULL,
    payload         JSONB NOT NULL,               -- copy, survives staging cleanup
    quarantined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved        BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_at     TIMESTAMPTZ,
    CONSTRAINT quarantine_resolved_consistent
        CHECK ((resolved AND resolved_at IS NOT NULL) OR (NOT resolved AND resolved_at IS NULL))
);
CREATE INDEX quarantine_open_idx ON integration.quarantine (run_id) WHERE NOT resolved;
