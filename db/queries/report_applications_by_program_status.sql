-- =====================================================================
-- report_applications_by_program_status.sql
-- What:  For one entry term, one row per program with application counts by
--        status, INCLUDING programs that received zero applications.
-- Why:   The typical "how is the cycle going?" question from an admissions
--        office. Zero rows matter: a program with no applicants is news.
-- Inputs: %(entry_term)s   e.g. '2027FA'
-- Output: program_code, program_name, degree_level, total, then one column
--         per status.
--
-- Paste-into-psql example: replace %(entry_term)s with '2027FA'.
-- =====================================================================

SELECT
    p.program_code,
    p.program_name,
    p.degree_level,
    -- COUNT(a.application_id), not COUNT(*): for a program with no matches
    -- the LEFT JOIN produces one row of NULLs, which COUNT(*) would count as 1.
    COUNT(a.application_id)                                    AS total,
    -- FILTER turns one grouped row into a "pivot": a count per status.
    COUNT(a.application_id) FILTER (WHERE a.status = 'submitted')    AS submitted,
    COUNT(a.application_id) FILTER (WHERE a.status = 'under_review') AS under_review,
    COUNT(a.application_id) FILTER (WHERE a.status = 'admitted')     AS admitted,
    COUNT(a.application_id) FILTER (WHERE a.status = 'waitlisted')   AS waitlisted,
    COUNT(a.application_id) FILTER (WHERE a.status = 'denied')       AS denied,
    COUNT(a.application_id) FILTER (WHERE a.status = 'withdrawn')    AS withdrawn
-- Start from program (every program), LEFT JOIN its applications.
FROM admissions.program AS p
LEFT JOIN admissions.application AS a
       ON a.program_id = p.program_id
      -- The term filter goes in ON, not WHERE. In WHERE, programs with no
      -- application rows (a.entry_term IS NULL) would be filtered out,
      -- silently turning the LEFT JOIN back into an INNER JOIN.
      AND a.entry_term = %(entry_term)s
WHERE p.is_active
GROUP BY p.program_code, p.program_name, p.degree_level
ORDER BY total DESC, p.program_code;

-- ---------------------------------------------------------------------
-- Interview talking points
--  * "INNER vs LEFT JOIN?" INNER keeps only matches; LEFT keeps every
--    program. Filtering the right-hand table in WHERE undoes a LEFT JOIN.
--  * "COUNT(*) vs COUNT(column)?" COUNT(column) skips NULLs, which is what
--    makes zero-application programs show 0 instead of 1.
--  * "How would you pivot statuses into columns?" COUNT(...) FILTER (WHERE ...)
--    (or SUM(CASE WHEN ... THEN 1 ELSE 0 END) in databases without FILTER).
-- ---------------------------------------------------------------------
