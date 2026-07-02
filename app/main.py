import logging
import os
import sys
import time
from contextlib import asynccontextmanager

import redis.asyncio as redis
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

# ---------------------------------------------------------------------------
# Logging: structured, stdout-based (12-factor). Docker/NGINX/CI all capture
# stdout/stderr, so we never write to local log files inside the container.
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"time":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
    stream=sys.stdout,
)
logger = logging.getLogger("app")

# ---------------------------------------------------------------------------
# Config (from environment — see .env.example)
# ---------------------------------------------------------------------------
DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql+asyncpg://postgres:postgres@postgres:5432/appdb"
)
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
APP_ENV = os.getenv("APP_ENV", "production")
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")

engine = create_async_engine(DATABASE_URL, pool_pre_ping=True, pool_size=5, max_overflow=5)
async_session = async_sessionmaker(engine, expire_on_commit=False)

redis_client: redis.Redis | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client
    logger.info(f"Starting up | env={APP_ENV} version={APP_VERSION}")
    redis_client = redis.from_url(REDIS_URL, decode_responses=True)

    # Create a minimal demo table if it doesn't exist yet.
    async with engine.begin() as conn:
        await conn.execute(
            text(
                """
                CREATE TABLE IF NOT EXISTS visits (
                    id SERIAL PRIMARY KEY,
                    path TEXT NOT NULL,
                    created_at TIMESTAMPTZ DEFAULT now()
                )
                """
            )
        )
    yield
    logger.info("Shutting down")
    await redis_client.aclose()
    await engine.dispose()


app = FastAPI(title="AI Deploy Stack Demo", version=APP_VERSION, lifespan=lifespan)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration_ms = round((time.time() - start) * 1000, 2)
    logger.info(
        f'method={request.method} path="{request.url.path}" '
        f"status={response.status_code} duration_ms={duration_ms}"
    )
    return response


# ---------------------------------------------------------------------------
# Health check — used by Docker HEALTHCHECK, NGINX upstream checks, and
# any external uptime monitor / load balancer.
# Returns 200 only if the app, Postgres, and Redis are all reachable.
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    status = {"app": "ok", "database": "unknown", "redis": "unknown"}
    http_status = 200

    try:
        async with async_session() as session:
            await session.execute(text("SELECT 1"))
        status["database"] = "ok"
    except Exception as e:
        logger.error(f"Health check DB failure: {e}")
        status["database"] = "error"
        http_status = 503

    try:
        await redis_client.ping()
        status["redis"] = "ok"
    except Exception as e:
        logger.error(f"Health check Redis failure: {e}")
        status["redis"] = "error"
        http_status = 503

    return JSONResponse(content=status, status_code=http_status)


@app.get("/")
async def root():
    # Increment a simple Redis counter and log a Postgres row — proves both
    # dependencies are wired in correctly, not just reachable.
    count = await redis_client.incr("visit_count")
    async with async_session() as session:
        await session.execute(text("INSERT INTO visits (path) VALUES (:p)"), {"p": "/"})
        await session.commit()
    return {"message": "Hello from FastAPI ", "visit_count": count, "env": APP_ENV}


@app.get("/api/visits")
async def visits():
    async with async_session() as session:
        result = await session.execute(
            text("SELECT id, path, created_at FROM visits ORDER BY id DESC LIMIT 20")
        )
        rows = [dict(r._mapping) for r in result]
    return {"recent_visits": rows}


@app.get("/api/echo/{value}")
async def echo(value: str):
    if not value.strip():
        raise HTTPException(status_code=400, detail="value must not be empty")
    return {"echo": value}
