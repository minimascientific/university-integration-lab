-- =====================================================================
-- upsert_application.sql
-- What:  Insert one application, or update the existing row with the same
--        portal_application_id. Re-running the same input changes nothing
--        (idempotent), and an older ("stale") version never overwrites a newer one.
-- Why:   The portal API can resend records (retries, overlapping pages) and
--        can deliver them out of order. This makes both harmless.
-- Used:  by the row-by-row fallback in src/integration_lab/sync.py (one call
--        per record). The normal path is the set-based promote_staging_batch.sql.
-- Inputs (psycopg named params):
--        %(portal_application_id)s, %(applicant_id)s, %(program_code)s,
--        %(entry_term)s, %(status)s, %(submitted_at)s, %(decided_at)s,
--        %(source_updated_at)s, %(run_id)s
-- Returns: one row (application_id, inserted) if inserted or updated;
--          NO row if skipped (unchanged, stale, or unknown program_code).
--
-- Paste-into-psql example (literal values instead of placeholders):
--   INSERT INTO admissions.application AS t
--       (portal_application_id, applicant_id, program_id, entry_term, status,
--        submitted_at, decided_at, source_updated_at, last_run_id)
--   SELECT 'APP-900001', 1, p.program_id, '2027FA', 'submitted',
--          '2026-09-10 10:00+00', NULL, '2026-09-10 12:00+00', NULL
--   FROM admissions.program p WHERE p.program_code = 'CSCI-BS'
--   ON CONFLICT (portal_application_id) DO UPDATE SET status = EXCLUDED.status
--   RETURNING application_id, (xmax = 0) AS inserted;
--   (needs an applicant with applicant_id = 1; run upsert_applicant first)
-- =====================================================================

INSERT INTO admissions.application AS t        -- t = the row already in the table
    (portal_application_id, applicant_id, program_id, entry_term, status,
     submitted_at, decided_at, source_updated_at, last_run_id)
-- INSERT ... SELECT instead of VALUES so we can translate program_code into
-- program_id in the same statement. If the code doesn't exist, the SELECT
-- returns zero rows, so nothing is inserted (no error). Python validation
-- quarantines unknown codes before we get here.
SELECT %(portal_application_id)s, %(applicant_id)s, p.program_id, %(entry_term)s,
       %(status)s, %(submitted_at)s, %(decided_at)s, %(source_updated_at)s, %(run_id)s
FROM admissions.program AS p
WHERE p.program_code = %(program_code)s
-- The conflict target must be a UNIQUE/PK column: portal_application_id is
-- the source system's identity for an application, our idempotency key.
ON CONFLICT (portal_application_id) DO UPDATE
-- EXCLUDED is the row we tried to insert (the incoming version).
SET applicant_id      = EXCLUDED.applicant_id,
    program_id        = EXCLUDED.program_id,
    entry_term        = EXCLUDED.entry_term,
    status            = EXCLUDED.status,
    submitted_at      = EXCLUDED.submitted_at,
    decided_at        = EXCLUDED.decided_at,
    source_updated_at = EXCLUDED.source_updated_at,
    last_run_id       = EXCLUDED.last_run_id,  -- which run last changed this row
    updated_at        = now()                  -- no trigger: we set it ourselves
-- Rule 1: only accept a NEWER version (ignore stale / out-of-order records).
WHERE EXCLUDED.source_updated_at > t.source_updated_at
-- Rule 2: and only if business data actually changed. IS DISTINCT FROM is a
-- NULL-safe "<>": NULL vs NULL counts as equal (decided_at is often NULL).
  AND (t.applicant_id, t.program_id, t.entry_term, t.status, t.submitted_at, t.decided_at)
      IS DISTINCT FROM
      (EXCLUDED.applicant_id, EXCLUDED.program_id, EXCLUDED.entry_term, EXCLUDED.status,
       EXCLUDED.submitted_at, EXCLUDED.decided_at)
-- xmax is a hidden system column: 0 on a freshly inserted row version,
-- non-zero when ON CONFLICT updated an existing row.
RETURNING application_id, (xmax = 0) AS inserted;

-- ---------------------------------------------------------------------
-- Interview talking points
--  * "How do you make a load idempotent?" A natural/source key with a UNIQUE
--    constraint + INSERT ... ON CONFLICT DO UPDATE, so reruns update not duplicate.
--  * "What if records arrive out of order?" Compare the source's own
--    last-modified time (source_updated_at), not our load time.
--  * "Why not just DELETE + INSERT?" It changes surrogate keys, breaks FKs,
--    loses created_at, and churns rows that didn't change.
-- ---------------------------------------------------------------------
