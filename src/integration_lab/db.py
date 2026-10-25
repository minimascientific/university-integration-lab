"""Database connection and SQL-file helpers."""

import os
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

PROJECT_ROOT = Path(__file__).resolve().parents[2]
QUERIES_DIR = PROJECT_ROOT / "db" / "queries"


def database_url() -> str:
    """DATABASE_URL from the environment, falling back to the project's .env file."""
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    env_file = PROJECT_ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("DATABASE_URL="):
                return line.split("=", 1)[1].strip()
    raise RuntimeError("DATABASE_URL is not set and no .env file was found")


def connect() -> psycopg.Connection:
    """Autocommit connection: use `with conn.transaction():` for atomic work."""
    return psycopg.connect(database_url(), autocommit=True, row_factory=dict_row)


def load_sql(name: str) -> str | None:
    """Read db/queries/<name>.sql without its full-line `--` comments.

    Comments are stripped so placeholders mentioned in header notes are not
    parsed as query parameters. Returns None if the file has no SQL yet.
    """
    text = (QUERIES_DIR / f"{name}.sql").read_text()
    sql = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("--")
    )
    return sql.strip() or None
