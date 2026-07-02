# Deployment Documentation

## 1. Stack overview

| Component | Role |
|---|---|
| FastAPI (`api`) | Application logic, `/health`, business endpoints |
| PostgreSQL | Persistent relational storage |
| Redis | Cache / counters / session store |
| NGINX | Reverse proxy, TLS termination, rate limiting |
| GitHub Actions | CI/CD: build image → push → SSH deploy |
| Certbot (optional) | Auto-renewing Let's Encrypt certificates |

All backend services (`api`, `postgres`, `redis`) sit on an internal Docker
network (`backend`) with **no ports published to the host**. Only NGINX
publishes 80/443. This means Postgres and Redis are unreachable from the
public internet even if you forget a firewall rule — Docker's own network
isolation is your first line of defense.

---

## 2. Prerequisites

- A VPS (Ubuntu 22.04/24.04 recommended) — DigitalOcean, Hetzner, Linode, AWS Lightsail, etc.
- A GitHub repository containing this project
- (Optional but recommended) a domain name pointed at the VPS's IP

---

## 3. One-time server setup

SSH into your fresh VPS as root, then:

```bash
# 1. Create a non-root deploy user
adduser deploy
usermod -aG sudo deploy

# 2. Copy your SSH key so CI can log in as `deploy` later
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy

# 3. Run the hardening script (firewall + fail2ban + auto updates)
curl -O https://raw.githubusercontent.com/<you>/<repo>/main/scripts/server_hardening.sh
chmod +x server_hardening.sh
./server_hardening.sh

# 4. Install Docker + Compose plugin
curl -fsSL https://get.docker.com | sh
usermod -aG docker deploy

# 5. Harden SSH (manual — do this last so you don't lock yourself out)
#    Edit /etc/ssh/sshd_config:
#      PasswordAuthentication no
#      PermitRootLogin no
#    Then: systemctl restart sshd
```

Log out and back in as `deploy` for the rest of the setup.

---

## 4. Clone and configure

```bash
su - deploy
git clone https://github.com/<you>/<repo>.git ~/ai-deploy-stack
cd ~/ai-deploy-stack
cp .env.example .env
nano .env   # set real POSTGRES_PASSWORD, REDIS_PASSWORD, DOCKERHUB_USERNAME
```

Generate strong passwords, e.g.: `openssl rand -base64 24`

---

## 5. First manual deploy (before CI/CD is wired up)

```bash
docker compose up -d --build
docker compose ps
curl http://localhost/health
# {"app":"ok","database":"ok","redis":"ok"}
```

Visit `http://YOUR_SERVER_IP/` in a browser — you should see the JSON
welcome response. This confirms NGINX → FastAPI → Postgres/Redis all work
**before** you touch SSL or CI/CD, which makes debugging far easier.

---

## 6. SSL setup approach

### If you have a domain (recommended path)

1. Point an `A` record for `yourdomain.com` (and `www`) at the server's IP.
2. Bring the stack up on plain HTTP first (step 5) and confirm it works.
3. Obtain a certificate with the `certbot` profile:

   ```bash
   docker compose --profile ssl run --rm certbot certonly \
     --webroot -w /var/www/certbot \
     -d yourdomain.com -d www.yourdomain.com \
     --email you@example.com --agree-tos --no-eff-email
   ```

4. Replace `nginx/conf.d/default.conf` with
   `nginx/conf.d/default.conf.ssl-example` (edit in the real domain name),
   then:

   ```bash
   docker compose up -d nginx
   docker compose --profile ssl up -d certbot   # keeps renewing every 12h
   ```

5. Test renewal works without downtime: `docker compose --profile ssl run --rm certbot renew --dry-run`

### If you do NOT have a domain

This is common for assignments/demos. Documented approach:

- Serve over **plain HTTP on the bare IP** (the default `default.conf`
  already supports this — nothing to change).
- Optionally generate a **self-signed certificate** for HTTPS testing only
  (browsers will show a warning, which is expected and fine for a demo):

  ```bash
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout nginx/selfsigned.key -out nginx/selfsigned.crt \
    -subj "/CN=$(curl -s ifconfig.me)"
  ```

  Then point `ssl_certificate`/`ssl_certificate_key` in an nginx server
  block at these files instead of Let's Encrypt paths.
- Alternatively, use **Cloudflare Tunnel** (`cloudflared`) or a free
  **Cloudflare-proxied subdomain** (e.g. from a free DNS provider) to get a
  real domain and free automatic TLS without owning a paid domain — see
  section 9 (Cloudflare integration) below.
- Real Let's Encrypt certificates require a real, publicly resolvable
  domain name — they cannot be issued for a bare IP address. This is a CA/
  browser-trust requirement, not a limitation of this setup.

---

## 7. CI/CD pipeline (GitHub Actions)

Workflow file: `.github/workflows/deploy.yml`

**Flow:** push to `main` → build Docker image → push to Docker Hub →
SCP updated `docker-compose.yml`/`nginx/` to server → SSH in → `docker
compose pull && up -d` → health-check loop confirms success → prune old
images.

### Required GitHub Secrets

Set these under **Repo → Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not your password) |
| `SERVER_HOST` | VPS IP or domain |
| `SERVER_USER` | `deploy` |
| `SERVER_SSH_KEY` | Private key (PEM) whose public half is in `~deploy/.ssh/authorized_keys` on the server |
| `SERVER_PORT` | SSH port (optional, defaults to 22) |

Generate a dedicated deploy key pair (don't reuse your personal key):

```bash
ssh-keygen -t ed25519 -f deploy_key -C "github-actions-deploy" -N ""
# Public key -> server's ~deploy/.ssh/authorized_keys
# Private key -> paste into SERVER_SSH_KEY secret
```

Once secrets are set, every push to `main` auto-deploys. You can also
trigger it manually from the Actions tab (`workflow_dispatch`).

---

## 8. Health checks

- **App-level**: `GET /health` checks the app process itself, then pings
  Postgres (`SELECT 1`) and Redis (`PING`). Returns `503` if either
  dependency is down, `200` only when everything is healthy.
- **Docker-level**: the `Dockerfile` `HEALTHCHECK` calls `/health` every
  30s; `docker compose ps` shows `healthy`/`unhealthy` status directly.
- **Compose-level**: `depends_on: condition: service_healthy` means the API
  container won't even start serving traffic until Postgres and Redis
  report healthy — avoids startup race conditions.
- **CI-level**: the deploy workflow polls `/health` after deploying and
  fails the pipeline (rather than silently leaving a broken deploy live) if
  it doesn't return `200` within ~30 seconds.

---

## 9. Logging strategy

- The FastAPI app logs structured JSON lines to **stdout** (never to a file
  inside the container) — this follows 12-factor app conventions and lets
  Docker's logging driver own log rotation.
- NGINX access/error logs are also redirected to stdout/stderr.
- `docker-compose.yml` sets the `json-file` driver with `max-size: 10m` and
  `max-file: 3` per service — bounds disk usage automatically (30MB cap per
  service) without needing logrotate.
- View logs live: `docker compose logs -f api`
- Ship logs off-box for real production use: point the Docker daemon's
  logging driver at `syslog`, `fluentd`, or a hosted service (Better
  Stack, Datadog, Grafana Loki) by changing the `logging:` block per
  service — no app code changes needed since everything already goes to
  stdout.

---

## 10. Backup & restart strategy

### Backups

- `scripts/backup.sh` — `pg_dump`s the database, gzips it, stores it in
  `~/backups/`, and prunes anything older than 7 days.
- Schedule via cron on the server:

  ```bash
  crontab -e
  # Daily backup at 2 AM
  0 2 * * * /home/deploy/ai-deploy-stack/scripts/backup.sh >> /home/deploy/backup.log 2>&1
  ```

- For real production, also copy backups off-box (e.g. `rclone` to S3/
  Backblaze) so a disk failure doesn't destroy backups too.
- Restore: `./scripts/restore.sh ~/backups/appdb_20260701_020000.sql.gz`

### Restart / recovery

- All services use `restart: unless-stopped` — Docker restarts crashed
  containers automatically, and the stack survives a host reboot.
- `scripts/restart.sh` does a safe manual restart: pulls latest images,
  recreates containers, and blocks until `/health` passes (or fails loudly
  with logs if it doesn't).
- Because Postgres/Redis data lives in named Docker volumes
  (`postgres_data`, `redis_data`), restarting or recreating containers
  never loses data — only `docker compose down -v` would (avoid `-v` in
  production).

---

## 11. Security measures summary

- Non-root user inside the API container.
- No database/cache ports exposed to the host or internet.
- NGINX security headers (`X-Frame-Options`, `X-Content-Type-Options`, etc).
- Rate limiting at the NGINX layer (`limit_req`).
- UFW firewall: only 22/80/443 open.
- fail2ban on SSH to block brute-force attempts.
- SSH key-only auth, root login disabled.
- Automatic OS security updates (`unattended-upgrades`).
- Secrets live only in `.env` (git-ignored) on the server and in GitHub
  Actions Secrets — never committed to the repo.
- Dedicated least-privilege deploy SSH key (not a personal key).

---

## 12. Zero-downtime notes

True zero-downtime blue/green deploys need a second app instance, a load
balancer that drains old connections, or a tool like `docker compose --scale`
with an external proxy. This project takes a pragmatic middle ground for a
single-VPS setup:

- `docker compose up -d --no-deps --build api` recreates only the API
  container while Postgres/Redis/NGINX keep running uninterrupted.
- The health-check loop in CI waits for the new container to report
  healthy before finishing, catching bad deploys immediately.
- Typical observed gap: 1–3 seconds while the old container stops and the
  new one binds the port — acceptable for most small/medium apps. For true
  zero-downtime, run 2 `api` replicas behind NGINX `upstream` with
  `least_conn` and roll them one at a time.
