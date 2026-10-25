-- =====================================================================
-- troubleshoot_duplicate_candidates.sql
-- What:  Groups of applicants who are probably the same person but have
--        different portal_applicant_ids: same normalised email, or same
--        last name + date of birth.
-- Why:   The UNIQUE key (portal_applicant_id) only stops exact repeats. If the
--        portal issues a second ID to the same person, both rows load fine.
--        We chose not to make email UNIQUE (shared family emails are legal),
--        so this report is how those cases get found and reviewed by a person.
-- Inputs: none
--
-- Paste-into-psql example: runs as-is (no placeholders).
-- =====================================================================

WITH keyed AS (
    -- Normalise before comparing: case and stray spaces shouldn't hide a match.
    SELECT applicant_id, portal_applicant_id, first_name, last_name, email,
           date_of_birth,
           lower(trim(email))                                      AS email_key,
           lower(trim(last_name)) || '|' || date_of_birth::text    AS name_dob_key
    FROM admissions.applicant
),
matches AS (
    SELECT 'same_email' AS match_rule, email_key AS match_key, *
    FROM keyed
    UNION ALL
    SELECT 'same_last_name_and_dob', name_dob_key, *
    FROM keyed
    WHERE date_of_birth IS NOT NULL  -- NULL || text is NULL: no key, no match
)
SELECT
    match_rule,
    match_key,
    COUNT(*)                                                      AS applicants,
    string_agg(portal_applicant_id, ', ' ORDER BY portal_applicant_id) AS portal_applicant_ids,
    string_agg(first_name || ' ' || last_name, ', ' ORDER BY portal_applicant_id) AS names
FROM matches
GROUP BY match_rule, match_key
-- HAVING filters groups after aggregation (WHERE filters rows before it).
-- More than one distinct person-ID sharing a key is a duplicate candidate.
HAVING COUNT(DISTINCT applicant_id) > 1
ORDER BY applicants DESC, match_rule, match_key;

-- ---------------------------------------------------------------------
-- Interview talking points
--  * "WHERE vs HAVING?" WHERE filters rows before grouping; HAVING filters
--    the groups after aggregates like COUNT are computed.
--  * "Why not enforce uniqueness on email?" Business rule: shared emails are
--    legitimate, so a hard constraint would reject valid data. Detect and
--    review instead.
--  * "Alternative approaches?" A self-join (a.applicant_id < b.applicant_id),
--    or window functions: COUNT(*) OVER (PARTITION BY email_key).
-- ---------------------------------------------------------------------
