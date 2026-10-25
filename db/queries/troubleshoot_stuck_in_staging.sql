-- =====================================================================
-- troubleshoot_stuck_in_staging.sql
-- What:  Staged records that were never processed (processed_at IS NULL),
--        oldest first, with their run's status and how long they've waited.
-- Why:   If a run crashes after staging but before promotion, records sit
--        in staging forever and never reach admissions.*. Nothing errors,
--        so you only notice if you look.
-- Inputs: %(older_than)s  an interval like '1 hour', or NULL for all.
--
-- Paste-into-psql example: replace %(older_than)s with '0 minutes'.
-- Check the index is used: put EXPLAIN in front of the SELECT
-- (with tiny tables Postgres may still prefer a sequential scan; that's fine).
-- =====================================================================

SELECT
    s.run_id,
    r.status                  AS run_status,
    r.started_at              AS run_started_at,
    s.staging_id,
    s.portal_application_id,
    s.received_at,
    now() - s.received_at     AS waiting_for,
    -- A run that is still 'running' long after it started has probably
    -- crashed without recording a failure.
    (r.status = 'running' AND r.started_at < now() - interval '1 hour')
                              AS run_probably_crashed
FROM integration.staging_application AS s
-- INNER JOIN is safe: run_id is NOT NULL with a foreign key, so every
-- staging row has exactly one run.
JOIN integration.integration_run AS r ON r.run_id = s.run_id
-- Matches the partial index staging_unprocessed_idx (WHERE processed_at IS NULL).
WHERE s.processed_at IS NULL
  AND s.received_at <= now() - COALESCE(%(older_than)s::interval, interval '0')
ORDER BY s.received_at;

-- ---------------------------------------------------------------------
-- Interview talking points
--  * "What's a partial index?" An index over only the rows matching a
--    WHERE clause, small and fast for "find the unfinished work".
--  * "How do you detect silent failures?" Look for work that started but
--    never finished: open staging rows, runs stuck in 'running'.
--  * "How would you recover?" Mark the run failed, then reprocess its
--    staging rows (the UPSERTs are idempotent, so replaying is safe).
-- ---------------------------------------------------------------------
