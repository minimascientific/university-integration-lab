"""Test fixtures: a throwaway database, separate from the dev database.

The session fixture (re)creates <dev db name>_test on the same server, applies
db/ddl and db/seed, and points DATABASE_URL at it. Each test starts from empty
tables (programs stay loaded).
"""

from pathlib import Path

import httpx
import psycopg
import pytest
from psycopg import sql

from integration_lab import db

ROOT = Path(__file__).resolve().parents[1]
BASE_URL = "http://portal.test"


@pytest.fixture(scope="session")
def test_db_url() -> str:
    dev_url = db.database_url()
    info = psycopg.conninfo.conninfo_to_dict(dev_url)
    test_name = f"{info['dbname']}_test"
    with psycopg.connect(dev_url, autocommit=True) as admin:
        admin.execute(
            sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
                sql.Identifier(test_name)
            )
        )
        admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(test_name)))
    url = psycopg.conninfo.make_conninfo(dev_url, dbname=test_name)
    with psycopg.connect(url, autocommit=True) as conn:
        for path in sorted((ROOT / "db" / "ddl").glob("*.sql")) + sorted(
            (ROOT / "db" / "seed").glob("*.sql")
        ):
            conn.execute(path.read_text())
    return url


@pytest.fixture
def conn(test_db_url, monkeypatch):
    """Connection to an emptied test database; sync.run_sync uses it too."""
    monkeypatch.setenv("DATABASE_URL", test_db_url)
    with db.connect() as c:
        c.execute(
            "TRUNCATE integration.quarantine, integration.staging_application,"
            " integration.integration_run, admissions.application,"
            " admissions.applicant RESTART IDENTITY CASCADE"
        )
        yield c


def portal_transport(scenario_records: list[dict] | None = None, status: int = 200):
    """httpx.MockTransport standing in for the portal.

    With no records given, it serves the real mock_portal app via FastAPI's
    TestClient, so the `scenario` query parameter works as in production.
    It also records how many requests were made (transport.calls).
    """
    from fastapi.testclient import TestClient

    from integration_lab.mock_portal import app

    client = TestClient(app)
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        if status != 200:
            return httpx.Response(status, json={"detail": "simulated"})
        if scenario_records is not None:
            return httpx.Response(200, json={"applications": scenario_records})
        r = client.get(request.url.path, params=dict(request.url.params))
        return httpx.Response(
            r.status_code,
            content=r.content,
            headers={"content-type": "application/json"},
        )

    transport = httpx.MockTransport(handler)
    transport.calls = calls
    return transport


def fetch_one(conn, query: str, params=None) -> dict:
    return conn.execute(query, params).fetchone()
