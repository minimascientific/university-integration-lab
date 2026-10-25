# University Application Integration Lab

A small, end-to-end data integration pipeline for university admissions data. A mock REST API
serves applicant and application records. A Python job fetches them, lands them in a PostgreSQL
staging table and validates them. Valid records are promoted into clean tables using idempotent
UPSERTs, and invalid ones go to quarantine. Every run is logged, and a set of troubleshooting
queries is included for diagnosing what went wrong.

> **Fictional data.** "Summit Ridge University", its systems and all data in this repository
> are fictional and synthetic. This project is not affiliated with, endorsed by, or modelled
> on any real institution, and contains no real personal data.

**Status:** work in progress. The schema is a draft and the pipeline code isn't written yet.

## Layout

```
db/ddl/       schema (runs automatically when the database is first created)
db/seed/      synthetic reference data (programs)
db/queries/   UPSERT, transaction, reporting and troubleshooting queries
src/          Python package: integration_lab
```

## Quickstart (macOS)

Requires [Colima](https://github.com/abiosoft/colima) (or any Docker runtime), the Docker CLI,
`uv`, and `psql` (Homebrew `libpq`).

```bash
colima start                       # start the Docker runtime
cp .env.example .env               # then edit the password
docker compose up -d               # Postgres 16; DDL runs on first start
uv sync                            # Python 3.12 environment + dependencies

source .env
psql "$DATABASE_URL" -f db/seed/001_programs.sql
psql "$DATABASE_URL" -c '\dt admissions.*'
```

Reset the database (re-runs the DDL): `docker compose down -v && docker compose up -d`
