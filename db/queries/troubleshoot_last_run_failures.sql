-- =====================================================================
-- troubleshoot_last_run_failures.sql
-- What:  Summary of one integration run (the latest by default): status,
--        duration, counts, error message, plus its OPEN quarantine rows
--        grouped by reason, with an example record for each reason.
-- Why:   First query to run when someone says "last night's load looked
--        wrong". It answers: did it run, did it fail, and what got rejected?
-- Inputs: %(run_id)s, or NULL for the most recent run.
-- Output: one row per quarantine reason (or a single row with NULL reason
--         if the run had no open quarantine records).
--
-- Paste-into-psql example: replace %(run_id)s with NULL (latest) or a run id.
-- =====================================================================

WITH target_run AS (
    SELECT *
    FROM integration.integration_run
    -- NULL means "latest run". ::bigint tells Postgres the parameter's type,
    -- which it can't infer from "IS NULL" alone.
    WHERE %(run_id)s::bigint IS NULL OR run_id = %(run_id)s::bigint
    -- run_id breaks ties: runs started in the same transaction share now().
    ORDER BY started_at DESC, run_id DESC
    LIMIT 1
),
open_quarantine AS (
    SELECT
        q.run_id,
        q.reason_code,
        COUNT(*)                     AS records,
        -- One sample per reason, so you can see what "bad" looks like
        -- without scrolling through every row.
        (array_agg(q.message ORDER BY q.quarantine_id))[1] AS example_message,
        (array_agg(q.payload ORDER BY q.quarantine_id))[1] AS example_payload
    FROM integration.quarantine AS q
    JOIN target_run AS r ON r.run_id = q.run_id
    WHERE NOT q.resolved
    GROUP BY q.run_id, q.reason_code
)
SELECT
    r.run_id,
    r.status,
    r.started_at,
    r.finished_at - r.started_at AS duration,  -- NULL while still running
    r.records_fetched,
    r.records_staged,
    r.records_inserted,
    r.records_updated,
    r.records_unchanged,
    r.records_quarantined,
    r.error_message,
    oq.reason_code,
    oq.records AS quarantined_for_reason,
    oq.example_message,
    oq.example_payload
FROM target_run AS r
-- LEFT JOIN so a clean run (or a run that failed before staging anything)
-- still returns its summary row.
LEFT JOIN open_quarantine AS oq ON oq.run_id = r.run_id
ORDER BY oq.records DESC NULLS LAST;

-- ---------------------------------------------------------------------
-- Interview talking points
--  * "Walk me through debugging a failed load." Check the run log first
--    (did it start/finish, error_message), then counts (fetched vs staged vs
--    promoted), then quarantine reasons, then individual payloads.
--  * "Why a CTE?" Names each step (pick the run, summarise quarantine), so
--    the final SELECT reads like the question being asked.
--  * "Why keep the payload in quarantine?" So bad records can be fixed and
--    replayed, and shown to the source-system owner as evidence.
-- ---------------------------------------------------------------------
