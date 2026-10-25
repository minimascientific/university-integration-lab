-- =====================================================================
-- upsert_applicant.sql
-- Purpose: insert a new applicant, or update an existing one, so running
--          the same input twice leaves the table unchanged (idempotent).
-- Inputs (psycopg named params): %(portal_applicant_id)s, %(first_name)s,
--          %(last_name)s, %(email)s, %(date_of_birth)s, %(source_updated_at)s
-- Returns: applicant_id, plus whether the row was inserted or updated.
-- Hints:
--   * INSERT ... ON CONFLICT (portal_applicant_id) DO UPDATE SET col = EXCLUDED.col
--   * Skip no-op updates: add WHERE (t.first_name, ...) IS DISTINCT FROM (EXCLUDED.first_name, ...)
--   * Skip stale records too: AND EXCLUDED.source_updated_at > t.source_updated_at
--   * Remember updated_at = now() (there is no trigger).
--   * RETURNING applicant_id, (xmax = 0) AS inserted   -- look up what xmax means
--   * If the WHERE skips the update, RETURNING gives no row. How will Python
--     tell "unchanged/stale" apart from "inserted" and "updated"?
-- =====================================================================

INSERT INTO admissions.applicant AS t
    (portal_applicant_id, first_name, last_name, email, date_of_birth, source_updated_at)
VALUES
    (%(portal_applicant_id)s, %(first_name)s, %(last_name)s, %(email)s,
     %(date_of_birth)s, %(source_updated_at)s)
-- portal_applicant_id is the identity we chose; a duplicate becomes an update.
ON CONFLICT (portal_applicant_id) DO UPDATE
SET first_name        = EXCLUDED.first_name,
    last_name         = EXCLUDED.last_name,
    email             = EXCLUDED.email,
    date_of_birth     = EXCLUDED.date_of_birth,
    source_updated_at = EXCLUDED.source_updated_at,
    updated_at        = now()
-- Only update if the incoming record is newer (stale/out-of-order records are ignored)...
WHERE EXCLUDED.source_updated_at > t.source_updated_at
-- ...and something actually changed (IS DISTINCT FROM treats NULL = NULL as "same").
  AND (t.first_name, t.last_name, t.email, t.date_of_birth)
      IS DISTINCT FROM
      (EXCLUDED.first_name, EXCLUDED.last_name, EXCLUDED.email, EXCLUDED.date_of_birth)
-- inserted = true for a new row, false for an update; no row at all = skipped.
RETURNING applicant_id, (xmax = 0) AS inserted;
