# Runbook: University Application Integration Lab

Four common situations, each with the symptom, the query to run, and the fix.
All queries are in [`db/queries/`](../db/queries/) and commented line by line.

**Setup for every command below** (from the project folder):

```bash
set -a; source .env; set +a
```

Some queries take a parameter written as `%(name)s` (the Python placeholder). In psql,
substitute it on the fly with `sed`, as shown below. `psql -x` prints one field per line,
which is easier to read for wide rows.

---

## 1. Portal down: the run failed

**Symptom.** `lab-sync` logs `Retry 1/3 ... Retry 3/3`, then
`failed: portal unavailable`. No new applications appear.

**Check.**

```bash
sed 's/%(run_id)s/NULL/g' db/queries/troubleshoot_last_run_failures.sql | psql -x "$DATABASE_URL"
```

Look for `status = failed`, `records_fetched = 0` and the `error_message`: `HTTP 500` means the
portal is up but erroring; `ConnectError` or `ConnectTimeout` means it is unreachable. Confirm
directly with `curl -i http://127.0.0.1:8001/health`.

**Fix.**
- Nothing to clean up. A failed fetch writes no staging or admissions rows, so the database
  is consistent.
- Once the portal is back (`/health` returns `{"status":"ok"}`), run `uv run lab-sync` again.
  The UPSERTs are idempotent, so re-running is always safe.
- If the error is a 4xx (for example `400`), the request itself is wrong, which is why it was
  not retried. Check the `--base-url`, `--limit` and `--scenario` arguments.

---

## 2. Records quarantined: the run is `partial`

**Symptom.** The run finishes with `status = partial` and `records_quarantined > 0`. Some
applications are missing from reports.

**Check.** The same query shows one row per reason code, with an example message and payload:

```bash
sed 's/%(run_id)s/NULL/g' db/queries/troubleshoot_last_run_failures.sql | psql -x "$DATABASE_URL"
```

To see every open record:

```sql
SELECT quarantine_id, run_id, reason_code, message, payload
FROM integration.quarantine
WHERE NOT resolved
ORDER BY quarantine_id;
```

| reason_code | Usual cause | Usual fix |
|---|---|---|
| `missing_required_field` | The source sent a blank or missing name or ID | Fix in the portal; it resends on the next sync |
| `invalid_format` | Bad email, future birth date, malformed term | Fix in the portal |
| `unknown_program` | New program code not in `admissions.program` | Add the program (seed file), then re-sync |
| `invalid_status` | The portal added a new status value | Decide whether to add it to the CHECK list in the DDL |
| `duplicate_in_batch` | The same application sent twice in one batch | Usually none: the newest copy was loaded |
| `constraint_violation` | Passed validation but the database rejected it | Read `message`; tighten validation to match |

**Fix.**
- Correct the data at the source (or add the missing reference data), then run `lab-sync`
  again. The corrected record loads normally.
- Mark the quarantine row as handled so it stops appearing in reports:

```sql
UPDATE integration.quarantine
SET resolved = TRUE, resolved_at = now()
WHERE quarantine_id = 123;   -- the row you handled
```

---

## 3. Duplicate applicants suspected

**Symptom.** Someone reports the same person appearing twice, for example two applicant records
for one student with different portal IDs. The unique keys cannot catch this: each portal ID is
different, and email is deliberately not unique (shared family emails are allowed).

**Check.**

```bash
psql "$DATABASE_URL" -f db/queries/troubleshoot_duplicate_candidates.sql
```

Each row is a group of applicants sharing a normalised email, or the same last name and date of
birth, listing their `portal_applicant_ids`.

**Fix.**
- These are *candidates*, not certainties. Confirm with the admissions office or the portal
  owner. Two siblings can share an email.
- The real fix is in the source system: merge the duplicate portal accounts there. The next sync
  then updates the surviving record.
- If a local merge is required, re-point the applications in one transaction, then delete the
  extra applicant. `ON DELETE RESTRICT` blocks the delete until no applications reference it:

```sql
BEGIN;
UPDATE admissions.application SET applicant_id = :keep_id WHERE applicant_id = :remove_id;
DELETE FROM admissions.applicant WHERE applicant_id = :remove_id;
COMMIT;
```

---

## 4. Rows stuck in staging

**Symptom.** A run stays `running` with no `finished_at`, or the counts don't add up
(`records_staged` is larger than inserted + updated + unchanged + quarantined). Usually the job
was killed, or the machine slept, after staging but before promotion.

**Check.**

```bash
sed "s/%(older_than)s/'10 minutes'/g" db/queries/troubleshoot_stuck_in_staging.sql | psql "$DATABASE_URL"
```

The output lists each unprocessed staging row, how long it has waited, and
`run_probably_crashed` (the run is still `running` more than an hour after it started).

**Fix.**
1. Make sure no sync is actually still running (`ps aux | grep lab-sync`).
2. Close the abandoned run so reports don't count it as in progress:

```sql
UPDATE integration.integration_run
SET status = 'failed', finished_at = now(),
    error_message = 'Abandoned: process stopped before promotion'
WHERE run_id = 42 AND status = 'running';
```

3. Run `uv run lab-sync` again. It fetches and stages the records afresh under a new run, and the
   idempotent UPSERTs make the replay safe.
4. Optionally clear the old staging rows by marking them processed:
   `UPDATE integration.staging_application SET processed_at = now() WHERE run_id = 42;`
