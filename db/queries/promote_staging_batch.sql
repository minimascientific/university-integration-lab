-- =====================================================================
-- promote_staging_batch.sql
-- What:  For one run, promote every staged record that is still unprocessed
--        and NOT quarantined into admissions.applicant and
--        admissions.application; mark all of the run's staging rows as
--        processed; and write the inserted/updated/unchanged counts onto the
--        run row.
-- Why:   One set-based statement instead of a loop of single-row UPSERTs:
--        fewer round trips, and the whole batch succeeds or fails together.
--
-- Transaction boundaries (the important part):
--   * A single SQL statement is always atomic. All the CTEs below are ONE
--     statement, so if any part fails (say a CHECK constraint), every insert,
--     update and staging mark in it is undone.
--   * The caller (sync.py) also wraps it in a larger transaction:
--         BEGIN;
--           INSERT INTO integration.quarantine ...   -- rejects found by Python
--           <this statement>
--         COMMIT;
--     so quarantine rows and promoted rows commit together, or not at all.
--   * What is NOT rolled back: the integration_run row and the raw staging
--     rows. They are committed earlier, on purpose, so a failed promotion
--     still leaves evidence (run status = 'failed', staged payloads intact).
--   * If this statement fails, sync.py rolls back and retries row by row with
--     SAVEPOINTs (upsert_applicant.sql + upsert_application.sql), so one bad
--     record is quarantined instead of sinking the whole batch.
--
-- Inputs: %(run_id)s
-- Returns: records_inserted, records_updated, records_unchanged
--
-- Paste-into-psql example:
--   BEGIN;  <statement with %(run_id)s replaced by a run id>;  ROLLBACK;
--   (use ROLLBACK to try it without keeping the changes)
-- =====================================================================

WITH
-- 1. The records to promote: this run, not yet processed, and not already
--    sent to quarantine by the Python validation step.
candidates AS (
    SELECT s.staging_id, s.payload
    FROM integration.staging_application AS s
    WHERE s.run_id = %(run_id)s
      AND s.processed_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM integration.quarantine AS q WHERE q.staging_id = s.staging_id
      )
),

-- 2. One row per applicant. Someone applying to two programs appears twice
--    in the batch, and ON CONFLICT DO UPDATE may not touch the same row twice
--    in one statement, so keep only their newest version.
--    DISTINCT ON (key) keeps the first row per key in ORDER BY order.
applicant_src AS (
    SELECT DISTINCT ON (payload -> 'applicant' ->> 'portal_applicant_id')
        payload -> 'applicant' ->> 'portal_applicant_id'      AS portal_applicant_id,
        payload -> 'applicant' ->> 'first_name'               AS first_name,
        payload -> 'applicant' ->> 'last_name'                AS last_name,
        payload -> 'applicant' ->> 'email'                    AS email,
        (payload -> 'applicant' ->> 'date_of_birth')::date    AS date_of_birth,
        (payload ->> 'updated_at')::timestamptz               AS source_updated_at
    FROM candidates
    -- ->  returns JSONB (to go a level deeper); ->> returns text.
    ORDER BY payload -> 'applicant' ->> 'portal_applicant_id',
             (payload ->> 'updated_at')::timestamptz DESC
),

-- 3. Upsert applicants: same rules as upsert_applicant.sql.
upserted_applicants AS (
    INSERT INTO admissions.applicant AS t
        (portal_applicant_id, first_name, last_name, email, date_of_birth, source_updated_at)
    SELECT portal_applicant_id, first_name, last_name, email, date_of_birth, source_updated_at
    FROM applicant_src
    ON CONFLICT (portal_applicant_id) DO UPDATE
    SET first_name        = EXCLUDED.first_name,
        last_name         = EXCLUDED.last_name,
        email             = EXCLUDED.email,
        date_of_birth     = EXCLUDED.date_of_birth,
        source_updated_at = EXCLUDED.source_updated_at,
        updated_at        = now()
    WHERE EXCLUDED.source_updated_at > t.source_updated_at
      AND (t.first_name, t.last_name, t.email, t.date_of_birth)
          IS DISTINCT FROM
          (EXCLUDED.first_name, EXCLUDED.last_name, EXCLUDED.email, EXCLUDED.date_of_birth)
    RETURNING t.applicant_id, t.portal_applicant_id
),

-- 4. Build application rows. Catch: every CTE in one statement sees the SAME
--    snapshot of the database, taken before the statement started. So a
--    brand-new applicant inserted in step 3 is NOT visible in
--    admissions.applicant here. Its applicant_id is only available from
--    step 3's RETURNING. Unchanged applicants (skipped by the WHERE, so not
--    RETURNed) are only visible in the table. COALESCE takes whichever exists.
application_src AS (
    SELECT DISTINCT ON (c.payload ->> 'portal_application_id')
        c.payload ->> 'portal_application_id'              AS portal_application_id,
        COALESCE(ua.applicant_id, a.applicant_id)          AS applicant_id,
        p.program_id,
        c.payload ->> 'entry_term'                         AS entry_term,
        c.payload ->> 'status'                             AS status,
        (c.payload ->> 'submitted_at')::timestamptz        AS submitted_at,
        (c.payload ->> 'decided_at')::timestamptz          AS decided_at,
        (c.payload ->> 'updated_at')::timestamptz          AS source_updated_at
    FROM candidates AS c
    -- INNER JOIN: drops a record whose program_code doesn't exist. Python has
    -- already quarantined those, so in practice nothing is dropped here.
    JOIN admissions.program AS p
      ON p.program_code = c.payload ->> 'program_code'
    LEFT JOIN upserted_applicants AS ua
      ON ua.portal_applicant_id = c.payload -> 'applicant' ->> 'portal_applicant_id'
    LEFT JOIN admissions.applicant AS a
      ON a.portal_applicant_id = c.payload -> 'applicant' ->> 'portal_applicant_id'
    ORDER BY c.payload ->> 'portal_application_id',
             (c.payload ->> 'updated_at')::timestamptz DESC
),

-- 5. Upsert applications: same rules as upsert_application.sql.
upserted_applications AS (
    INSERT INTO admissions.application AS t
        (portal_application_id, applicant_id, program_id, entry_term, status,
         submitted_at, decided_at, source_updated_at, last_run_id)
    SELECT portal_application_id, applicant_id, program_id, entry_term, status,
           submitted_at, decided_at, source_updated_at, %(run_id)s
    FROM application_src
    ON CONFLICT (portal_application_id) DO UPDATE
    SET applicant_id      = EXCLUDED.applicant_id,
        program_id        = EXCLUDED.program_id,
        entry_term        = EXCLUDED.entry_term,
        status            = EXCLUDED.status,
        submitted_at      = EXCLUDED.submitted_at,
        decided_at        = EXCLUDED.decided_at,
        source_updated_at = EXCLUDED.source_updated_at,
        last_run_id       = EXCLUDED.last_run_id,
        updated_at        = now()
    WHERE EXCLUDED.source_updated_at > t.source_updated_at
      AND (t.applicant_id, t.program_id, t.entry_term, t.status, t.submitted_at, t.decided_at)
          IS DISTINCT FROM
          (EXCLUDED.applicant_id, EXCLUDED.program_id, EXCLUDED.entry_term, EXCLUDED.status,
           EXCLUDED.submitted_at, EXCLUDED.decided_at)
    RETURNING (xmax = 0) AS inserted
),

-- 6. Mark ALL of this run's staging rows processed: promoted ones and
--    quarantined ones alike ("processed" = a decision was made). Data-modifying
--    CTEs run even if nothing else references them.
marked AS (
    UPDATE integration.staging_application
    SET processed_at = now()
    WHERE run_id = %(run_id)s
      AND processed_at IS NULL
    RETURNING staging_id
)

-- 7. Record the counts on the run. Unchanged = rows we tried to upsert that
--    the WHERE clause skipped (already up to date, or stale).
UPDATE integration.integration_run AS r
SET records_inserted  = (SELECT COUNT(*) FROM upserted_applications WHERE inserted),
    records_updated   = (SELECT COUNT(*) FROM upserted_applications WHERE NOT inserted),
    records_unchanged = (SELECT COUNT(*) FROM application_src)
                      - (SELECT COUNT(*) FROM upserted_applications)
WHERE r.run_id = %(run_id)s
RETURNING r.records_inserted, r.records_updated, r.records_unchanged;

-- ---------------------------------------------------------------------
-- Interview talking points
--  * "What happens if the load fails halfway?" Nothing is half-applied: the
--    promotion is one transaction, so it all rolls back; the run is marked
--    'failed' and its staged rows stay unprocessed, ready to replay.
--  * "Why staging before the real tables?" Keeps the raw evidence, lets bad
--    records be quarantined instead of lost, and makes reprocessing possible.
--  * "Set-based vs row-by-row?" Set-based is much faster and atomic; row-by-row
--    with SAVEPOINTs isolates one bad record. This pipeline does set-based
--    first and falls back to row-by-row only when the batch fails.
-- ---------------------------------------------------------------------
