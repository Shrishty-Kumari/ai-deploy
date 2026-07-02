# AI Deploy Stack

A production-style deployment of a FastAPI app with PostgreSQL, Redis, and
NGINX, fully Dockerized, with a GitHub Actions CI/CD pipeline that
auto-deploys to a VPS on every push to `main`.

## Stack

FastAPI · PostgreSQL 16 · Redis 7 · NGINX · Docker Compose · GitHub Actions

## Quick start (local)

```bash
git clone <this-repo>
cd ai-deploy-stack
cp .env.example .env        # edit passwords
docker compose up -d --build
curl http://localhost/health
curl http://localhost/
```

## Docs

- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — full VPS setup, SSL, CI/CD
  secrets, security, logging, backup/restart strategy
- [`docs/AWS_SETUP.md`](docs/AWS_SETUP.md) — deploying on **AWS EC2 Free
  Tier** instead of a paid VPS, including a launch script
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture diagram and
  request/deploy flow

## Project layout

```
.
├── app/                      # FastAPI application code
│   ├── main.py
│   └── requirements.txt
├── nginx/
│   ├── nginx.conf            # global nginx config (security headers, gzip)
│   └── conf.d/
│       ├── default.conf              # HTTP-only, works with no domain
│       └── default.conf.ssl-example  # HTTPS config once you have a domain
├── scripts/
│   ├── backup.sh              # pg_dump -> gzip, prunes >7 days old
│   ├── restore.sh             # restore from a backup file
│   ├── restart.sh             # safe restart with health-check wait
│   └── server_hardening.sh    # one-time UFW + fail2ban + auto-updates setup
├── .github/workflows/deploy.yml   # CI/CD: build -> push -> SSH deploy
├── docker-compose.yml
├── Dockerfile
├── .env.example
└── docs/
```

## Endpoints

| Endpoint | Description |
|---|---|
| `GET /` | Demo route — increments Redis counter, logs a Postgres row |
| `GET /health` | Health check: app + Postgres + Redis status |
| `GET /api/visits` | Last 20 recorded visits from Postgres |
| `GET /api/echo/{value}` | Simple echo endpoint |

## Deploying to a real VPS

See [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the full step-by-step
walkthrough, including server hardening, SSL (with or without a domain),
and wiring up GitHub Actions secrets.