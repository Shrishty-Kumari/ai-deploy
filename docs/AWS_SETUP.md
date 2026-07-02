# Deploying on AWS EC2 Free Tier (no VPS cost)

This covers using AWS instead of a paid VPS. It's the same Docker Compose
stack — only the server-provisioning step changes.

## What you get for free

- **EC2 Free Tier**: 750 hrs/month of `t2.micro` or `t3.micro` (1 vCPU,
  1 GB RAM) for the first 12 months of a new AWS account. 750 hrs covers
  one instance running continuously all month.
- **Elastic IP**: free *while attached to a running instance* (you get
  charged only if you allocate one and leave it unattached, or attach it
  to a stopped instance).
- **30 GB of EBS storage** free — more than enough for this stack.

1 GB RAM is tight for Postgres + Redis + FastAPI + NGINX together, but
workable for a demo/assignment. If things feel sluggish, add a 1-2 GB swap
file (command included below).

---

## 1. Launch the instance

**Console (easiest):**
1. EC2 → Launch Instance
2. Name: `ai-deploy-stack`
3. AMI: **Ubuntu Server 24.04 LTS** (free tier eligible)
4. Instance type: `t2.micro` (or `t3.micro` if offered as free-tier eligible)
5. Key pair: create new, download the `.pem` file — you'll need it for SSH
   and for the `SERVER_SSH_KEY` GitHub secret
6. Network settings → Edit → Security group: allow inbound
   - SSH (22) — restrict to "My IP" if possible
   - HTTP (80) — from anywhere
   - HTTPS (443) — from anywhere
7. Storage: default 8-30 GB gp3 is fine
8. Launch

**Or via AWS CLI** — see `scripts/aws_launch_instance.sh` in this repo,
which does steps 1-6 for you.

## 2. Allocate an Elastic IP (so the address doesn't change on reboot)

Console: EC2 → Elastic IPs → Allocate → Associate with your instance.
(Free as long as it stays attached to a running instance — don't leave it
floating unattached, that does get billed.)

## 3. Connect and set up

```bash
chmod 400 ai-deploy-stack.pem
ssh -i ai-deploy-stack.pem ubuntu@<ELASTIC_IP>
```

From here, follow `docs/DEPLOYMENT.md` sections 3-5 exactly as written —
`ubuntu` is your equivalent of the `deploy` user (Ubuntu AMIs already give
it sudo + it's not root), so you can skip the "create a deploy user" step
and just use `ubuntu` directly, or create a separate `deploy` user if you
prefer extra separation.

```bash
# Hardening (firewall + fail2ban) — note: AWS Security Groups already
# block everything except 22/80/443 at the network level, so UFW here is
# a second, redundant layer of defense (still worth having)
git clone https://github.com/<you>/<repo>.git ~/ai-deploy-stack
cd ~/ai-deploy-stack
chmod +x scripts/*.sh
sudo ./scripts/server_hardening.sh

curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu
# log out and back in for the group change to apply
exit
ssh -i ai-deploy-stack.pem ubuntu@<ELASTIC_IP>

cd ~/ai-deploy-stack
cp .env.example .env
nano .env   # set real passwords
docker compose up -d --build
curl http://localhost/health
```

Visit `http://<ELASTIC_IP>/` in your browser to confirm it's live.

## 4. (Optional) add a 1-2 GB swap file

`t2.micro`'s 1 GB RAM can get tight with 4 containers running. This adds
breathing room and prevents the OOM killer from taking down Postgres:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 5. GitHub Actions secrets for AWS

Same secrets as documented in `docs/DEPLOYMENT.md` §7, with these AWS-specific values:

| Secret | Value |
|---|---|
| `SERVER_HOST` | Your Elastic IP |
| `SERVER_USER` | `ubuntu` |
| `SERVER_SSH_KEY` | Contents of your `.pem` file (the whole thing, including `-----BEGIN...` lines) |
| `SERVER_PORT` | `22` (default) |

## 6. SSL without a domain, on AWS

Same options as the general doc (`docs/DEPLOYMENT.md` §6). Since you
already have an AWS account, two extra options open up:

- **Route 53**: buy a cheap domain (`.com` ~$12/yr, some TLDs cheaper) and
  point it at your Elastic IP — then Let's Encrypt works normally.
- **Cloudflare on top of the Elastic IP**: get any free domain (e.g. from
  a free-DNS provider, or a cheap Namecheap domain), set its nameservers
  to Cloudflare, add an A record pointing at your Elastic IP, and turn on
  Cloudflare's proxy — you get free automatic HTTPS at the edge even
  without running certbot yourself.
- Otherwise: stick with the self-signed cert / plain-HTTP approach already
  documented — perfectly fine for an assignment demo.

## 7. Cost safety checklist (avoid surprise charges)

- Stick to `t2.micro`/`t3.micro` — anything bigger isn't covered by free tier.
- Don't allocate extra Elastic IPs you're not using.
- Set a **Billing Alarm** (Billing → Budgets → create a $1 budget alert) so
  you get emailed if anything ever starts charging.
- When you're done with the assignment, either **stop** the instance (no
  compute charges while stopped, small EBS storage charge remains) or
  **terminate** it entirely (deletes everything, zero ongoing cost).
