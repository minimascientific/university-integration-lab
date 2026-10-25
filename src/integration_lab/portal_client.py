"""HTTP client for the applicant portal API, with retries."""

import logging
import time

import httpx

log = logging.getLogger(__name__)


class PortalUnavailable(Exception):
    """The portal could not be reached or kept returning server errors."""


def fetch_applications(
    base_url: str,
    scenario: str = "normal",
    limit: int = 50,
    retries: int = 3,
    backoff_seconds: float = 0.5,
    timeout_seconds: float = 5.0,
    logger: logging.Logger | logging.LoggerAdapter = log,
) -> list[dict]:
    """GET /applications. Retries connection errors and 5xx responses with
    exponential backoff (0.5s, 1s, 2s); raises PortalUnavailable when exhausted.
    4xx responses are not retried: they mean our request is wrong.
    """
    url = f"{base_url.rstrip('/')}/applications"
    params = {"limit": limit, "scenario": scenario}
    last_error = ""

    with httpx.Client(timeout=timeout_seconds) as client:
        for attempt in range(retries + 1):
            if attempt:
                delay = backoff_seconds * 2 ** (attempt - 1)
                logger.warning(
                    "Retry %d/%d in %.1fs (%s)", attempt, retries, delay, last_error
                )
                time.sleep(delay)
            try:
                response = client.get(url, params=params)
            except httpx.TransportError as exc:
                last_error = f"{type(exc).__name__}: {exc}"
                continue
            if response.status_code >= 500:
                last_error = f"HTTP {response.status_code}"
                continue
            response.raise_for_status()
            return response.json()["applications"]

    raise PortalUnavailable(
        f"{url} failed after {retries + 1} attempts; last error: {last_error}"
    )
