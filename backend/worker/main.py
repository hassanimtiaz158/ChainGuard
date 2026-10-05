"""RQ worker entrypoint for ChainGuard analysis jobs.

The worker consumes the `analysis` queue and is the only process that talks to
the analyzer sandbox. Uploaded Solidity is compiled and statically analyzed
inside that sandbox; it is never deployed and never executed.
"""

from __future__ import annotations

import logging

from app.config import get_settings
from redis import Redis
from rq import Queue, Worker

QUEUE_NAME = "analysis"


def build_worker() -> Worker:
    """Create the worker bound to the analysis queue."""
    settings = get_settings()
    connection: Redis = Redis.from_url(settings.redis_url)
    queue = Queue(QUEUE_NAME, connection=connection)
    return Worker([queue], name="chainguard-analysis")


def main() -> None:
    """Run the worker until it is asked to stop."""
    settings = get_settings()
    logging.basicConfig(
        level=settings.log_level.upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    logging.getLogger(__name__).info("Starting analysis worker on queue %r", QUEUE_NAME)
    build_worker().work(with_scheduler=True)


if __name__ == "__main__":
    main()
