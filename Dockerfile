# ---------- Build stage ----------
FROM python:3.12-slim AS builder

WORKDIR /build
COPY app/requirements.txt .

# Build wheels so the final image doesn't need gcc/build tools at all
RUN pip install --no-cache-dir --upgrade pip \
    && pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ---------- Runtime stage ----------
FROM python:3.12-slim

# Security: run as a non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Minimal runtime deps (curl needed for HEALTHCHECK)
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /wheels /wheels
COPY app/requirements.txt .
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

COPY app .

RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:8000/health || exit 1

# gunicorn + uvicorn workers = production-grade process management
CMD ["gunicorn", "main:app", "-k", "uvicorn.workers.UvicornWorker", \
     "--bind", "0.0.0.0:8000", "--workers", "2", \
     "--access-logfile", "-", "--error-logfile", "-"]