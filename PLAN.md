# Multi-Service VPS Setup with Docker Compose + Caddy

A maintainable, version-trackable, error-resistant setup for running multiple containerized services — each with their own dependencies — on a single Ubuntu VPS.

**Stack:** Docker Compose · Caddy (reverse proxy + automatic TLS) · GitHub Actions (CI/CD) · GitHub Container Registry (ghcr.io)

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Repository Structure](#repository-structure)
- [Initial VPS Setup](#initial-vps-setup)
- [Caddy — Reverse Proxy and TLS](#caddy--reverse-proxy-and-tls)
- [Project Compose Files](#project-compose-files)
- [Environment Variables and Secrets](#environment-variables-and-secrets)
- [CI/CD with GitHub Actions](#cicd-with-github-actions)
- [Backups](#backups)
- [Shared Dependencies (Optional)](#shared-dependencies-optional)
- [Monitoring](#monitoring)
- [Maintenance and Operations](#maintenance-and-operations)
- [Scaling Limits and Migration Path](#scaling-limits-and-migration-path)

---

## Architecture Overview

Each project is a self-contained Docker Compose stack with its own backing services (databases, caches, search engines). A single Caddy instance sits in front of everything, terminates TLS, and routes traffic to the correct app container.

```
                    Internet
                       │
                 ┌─────┴─────┐
                 │   Caddy    │  ← automatic Let's Encrypt TLS
                 │  :80 :443  │
                 └──┬───┬───┬─┘
                    │   │   │
            ┌───────┘   │   └───────┐
            │           │           │
    ┌───────┴──┐  ┌─────┴────┐  ┌──┴──────────┐
    │ saas-app │  │ internal  │  │  marketing  │
    │   :8000  │  │   :3000   │  │    :80      │
    └───┬──────┘  └────┬──────┘  └─────────────┘
        │              │
   ┌────┴────┐    ┌────┴────┐
   │ mysql   │    │  redis  │    ← isolated backend networks
   │ redis   │    └─────────┘      not reachable by other projects
   │ meili   │
   └─────────┘
```

**Key principles:**

- The `proxy` network is the only shared Docker network. Only web-facing app containers join it.
- Each project's backing services live on a private `backend` network, unreachable by Caddy or other projects.
- Every piece of config is a file in Git. No GUI-driven state, no manual server changes.
- Each project deploys independently via its own GitHub Actions workflow.

---

## Repository Structure

A single Git repository holds all infrastructure config:

```
infrastructure/
├── README.md
├── caddy/
│   ├── docker-compose.yml
│   └── Caddyfile
├── saas-app/
│   ├── docker-compose.yml
│   ├── .env.example
│   └── .env                    ← gitignored, created on server
├── internal-tool/
│   ├── docker-compose.yml
│   ├── .env.example
│   └── .env
├── marketing-site/
│   ├── docker-compose.yml
│   └── .env.example
├── backups/
│   ├── docker-compose.yml
│   └── backup.sh
├── scripts/
│   ├── bootstrap.sh            ← initial VPS provisioning
│   └── deploy.sh               ← generic deploy helper
├── .github/
│   └── workflows/
│       ├── deploy-caddy.yml
│       ├── deploy-saas.yml
│       ├── deploy-internal.yml
│       └── deploy-marketing.yml
└── .gitignore
```

`.gitignore`:

```gitignore
**/.env
!**/.env.example
```

---

## Initial VPS Setup

Run once on a fresh Ubuntu 24.04 VPS. This can also live as `scripts/bootstrap.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- System updates ---
apt update && apt upgrade -y

# --- Install Docker ---
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# --- Add deploy user (optional, run Docker without root) ---
useradd -m -s /bin/bash deploy
usermod -aG docker deploy

# --- Install Tailscale (optional, for secure SSH from CI) ---
curl -fsSL https://tailscale.com/install.sh | sh
# then: tailscale up --auth-key=tskey-auth-XXXXX

# --- Create the shared proxy network ---
docker network create proxy

# --- Create project directory ---
mkdir -p /opt/infrastructure
chown deploy:deploy /opt/infrastructure

# --- Firewall ---
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp      # SSH (or Tailscale port)
ufw allow 80/tcp      # HTTP  (Caddy)
ufw allow 443/tcp     # HTTPS (Caddy)
ufw enable

echo "VPS bootstrap complete."
```

> **Tailscale is recommended** for CI/CD SSH access. It means port 22 never needs to be exposed to the public internet. GitHub Actions connects to the VPS over Tailscale's encrypted mesh network.

---

## Caddy — Reverse Proxy and TLS

Caddy handles TLS certificate provisioning and renewal automatically via Let's Encrypt. No certbot, no cron jobs, no manual renewal.

### `caddy/docker-compose.yml`

```yaml
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"   # HTTP/3 (QUIC)
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data       # TLS certificates
      - caddy_config:/config
    networks:
      - proxy

networks:
  proxy:
    external: true

volumes:
  caddy_data:
  caddy_config:
```

### `caddy/Caddyfile`

```caddyfile
# Global options
{
    email you@example.com       # used for Let's Encrypt account
}

# --- SaaS Application ---
saas.example.com {
    reverse_proxy saas-app-app-1:8000
}

# --- Internal Tool ---
internal.example.com {
    reverse_proxy internal-tool-app-1:3000

    # Optional: restrict to Tailscale / VPN IPs
    # @blocked not remote_ip 100.64.0.0/10
    # respond @blocked 403
}

# --- Marketing Site ---
example.com {
    reverse_proxy marketing-site-web-1:80
}

www.example.com {
    redir https://example.com{uri} permanent
}
```

> **Container naming:** Docker Compose generates container names as `{project}-{service}-{n}`. The project name defaults to the directory name. So `saas-app/docker-compose.yml` with a service named `app` becomes `saas-app-app-1`. Use these names in the Caddyfile.

Start Caddy:

```bash
cd /opt/infrastructure/caddy
docker compose up -d
```

---

## Project Compose Files

### Example: SaaS App (with MySQL + Redis + Meilisearch)

#### `saas-app/docker-compose.yml`

```yaml
services:
  app:
    image: ghcr.io/your-org/saas-app:latest
    restart: unless-stopped
    env_file: .env
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      meilisearch:
        condition: service_started
    networks:
      - proxy        # reachable by Caddy
      - backend      # reachable by dependencies

  mysql:
    image: mysql:8.4
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend      # NOT on proxy — invisible to Caddy and other projects

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend

  meilisearch:
    image: getmeili/meilisearch:v1.12
    restart: unless-stopped
    environment:
      MEILI_MASTER_KEY: ${MEILI_MASTER_KEY}
      MEILI_ENV: production
      MEILI_DB_PATH: /meili_data
    volumes:
      - meili_data:/meili_data
    networks:
      - backend

networks:
  proxy:
    external: true
  backend:
    # internal network, auto-created, scoped to this project

volumes:
  mysql_data:
  redis_data:
  meili_data:
```

#### `saas-app/.env.example`

```env
# App
APP_ENV=production
APP_URL=https://saas.example.com

# MySQL
MYSQL_ROOT_PASSWORD=CHANGE_ME
MYSQL_DATABASE=saas
MYSQL_USER=saas
MYSQL_PASSWORD=CHANGE_ME
DATABASE_URL=mysql://saas:CHANGE_ME@mysql:3306/saas

# Redis
REDIS_PASSWORD=CHANGE_ME
REDIS_URL=redis://:CHANGE_ME@redis:6379

# Meilisearch
MEILI_MASTER_KEY=CHANGE_ME
MEILI_URL=http://meilisearch:7700
```

### Example: Internal Tool (with Redis)

#### `internal-tool/docker-compose.yml`

```yaml
services:
  app:
    image: ghcr.io/your-org/internal-tool:latest
    restart: unless-stopped
    env_file: .env
    depends_on:
      redis:
        condition: service_healthy
    networks:
      - proxy
      - backend

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend

networks:
  proxy:
    external: true
  backend:

volumes:
  redis_data:
```

### Example: Marketing Site (static, no dependencies)

#### `marketing-site/docker-compose.yml`

```yaml
services:
  web:
    image: ghcr.io/your-org/marketing-site:latest
    restart: unless-stopped
    networks:
      - proxy

networks:
  proxy:
    external: true
```

---

## Environment Variables and Secrets

**Rule: `.env` files never enter Git.** Only `.env.example` (with placeholder values) is committed. On the server, `.env` files are created once and updated manually or via CI secrets.

For CI/CD, secrets are stored in GitHub repository or environment secrets and injected during deploy:

```yaml
# In a GitHub Actions workflow
- name: Update .env on server
  run: |
    ssh deploy@$VPS_IP "cat > /opt/infrastructure/saas-app/.env << 'EOF'
    APP_ENV=production
    MYSQL_ROOT_PASSWORD=${{ secrets.SAAS_MYSQL_ROOT_PASSWORD }}
    MYSQL_DATABASE=saas
    MYSQL_USER=saas
    MYSQL_PASSWORD=${{ secrets.SAAS_MYSQL_PASSWORD }}
    DATABASE_URL=mysql://saas:${{ secrets.SAAS_MYSQL_PASSWORD }}@mysql:3306/saas
    REDIS_PASSWORD=${{ secrets.SAAS_REDIS_PASSWORD }}
    REDIS_URL=redis://:${{ secrets.SAAS_REDIS_PASSWORD }}@redis:6379
    MEILI_MASTER_KEY=${{ secrets.SAAS_MEILI_MASTER_KEY }}
    MEILI_URL=http://meilisearch:7700
    EOF"
```

> **Alternative:** Use Docker secrets, SOPS-encrypted files in Git, or Doppler/Infisical for more advanced secret management. For a single VPS, `.env` files managed via CI secrets are the simplest option that works.

---

## CI/CD with GitHub Actions

Each project gets its own workflow. When you push a change, only the affected service redeploys.

### `deploy-saas.yml` — Full example

```yaml
name: Deploy SaaS App

on:
  push:
    branches: [main]
    paths:
      - 'saas-app/**'
  workflow_dispatch:            # manual trigger

env:
  PROJECT_DIR: /opt/infrastructure/saas-app
  REGISTRY: ghcr.io
  IMAGE_NAME: your-org/saas-app

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        uses: docker/build-push-action@v6
        with:
          context: ./saas-app
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}

  deploy:
    runs-on: ubuntu-latest
    needs: build-and-push

    steps:
      # Option A: Tailscale (recommended — no exposed SSH port)
      - name: Connect to Tailscale
        uses: tailscale/github-action@v2
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      # Option B: Direct SSH (if not using Tailscale)
      # Ensure port 22 is firewalled to GitHub Actions IPs

      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}        # Tailscale IP or public IP
          username: deploy
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
            cd ${{ env.PROJECT_DIR }}
            docker compose pull app
            docker compose up -d --no-deps app
            docker image prune -f
```

### `deploy-caddy.yml` — Caddy config updates

```yaml
name: Deploy Caddy Config

on:
  push:
    branches: [main]
    paths:
      - 'caddy/**'
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Connect to Tailscale
        uses: tailscale/github-action@v2
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      - name: Update Caddyfile and reload
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: deploy
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
            cd /opt/infrastructure
            git pull origin main
            docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

> **Why `--no-deps` in the app deploy?** It ensures only the app container is recreated. MySQL, Redis, and Meilisearch keep running undisturbed. Their images only update when you explicitly change their version tags in the compose file.

---

## Backups

### Database Backups via Cron

Create a script that runs on the host via cron:

#### `backups/backup.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/backups"
DATE=$(date +%Y-%m-%d_%H-%M)
S3_BUCKET="s3://your-backup-bucket"

mkdir -p "$BACKUP_DIR"

# --- MySQL (SaaS App) ---
docker exec saas-app-mysql-1 mysqldump \
    -u root -p"${MYSQL_ROOT_PASSWORD}" \
    --all-databases --single-transaction \
    > "$BACKUP_DIR/saas-mysql-$DATE.sql"

gzip "$BACKUP_DIR/saas-mysql-$DATE.sql"

# --- Redis (SaaS App) ---
docker exec saas-app-redis-1 redis-cli -a "${REDIS_PASSWORD}" BGSAVE
sleep 5
docker cp saas-app-redis-1:/data/dump.rdb "$BACKUP_DIR/saas-redis-$DATE.rdb"

# --- Meilisearch (SaaS App) ---
# Meilisearch supports dump creation via API
curl -s -X POST "http://localhost:7700/dumps" \
    -H "Authorization: Bearer ${MEILI_MASTER_KEY}" || true

# --- Upload to S3-compatible storage ---
aws s3 sync "$BACKUP_DIR" "$S3_BUCKET/$DATE/" --storage-class STANDARD_IA

# --- Cleanup local backups older than 7 days ---
find "$BACKUP_DIR" -type f -mtime +7 -delete

echo "Backup completed: $DATE"
```

#### Cron entry (on host)

```bash
# /etc/cron.d/infrastructure-backup
0 3 * * * deploy /opt/infrastructure/backups/backup.sh >> /var/log/backups.log 2>&1
```

### Alternative: Container-based Backups

Use a tool like `offen/docker-volume-backup` in its own compose file for a fully containerized approach to backing up named volumes to S3.

---

## Shared Dependencies (Optional)

If multiple projects need the same database engine and RAM is tight, extract it into a shared service:

### `shared-services/docker-compose.yml`

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      # init scripts to create per-project databases:
      - ./init-databases.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - shared-backend

networks:
  shared-backend:
    name: shared-backend     # explicit name for cross-project reference

volumes:
  postgres_data:
```

Then in consuming projects, reference the shared network:

```yaml
# In another project's docker-compose.yml
services:
  app:
    networks:
      - proxy
      - shared-backend

networks:
  proxy:
    external: true
  shared-backend:
    external: true
```

> **Tradeoff warning:** Shared dependencies mean a bad migration in one project can corrupt data used by another. Keep projects isolated unless resource constraints force sharing, and document the coupling explicitly.

---

## Monitoring

### Lightweight: `docker stats` + log tailing

```bash
# Live resource usage
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Follow logs for a specific service
docker compose -f saas-app/docker-compose.yml logs -f app

# Follow all logs across a project
docker compose -f saas-app/docker-compose.yml logs -f --tail=100
```

### Production: Prometheus + Grafana (optional)

If you need dashboards and alerting, add a monitoring stack:

```yaml
# monitoring/docker-compose.yml
services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - proxy
      - monitoring

  grafana:
    image: grafana/grafana:latest
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
    volumes:
      - grafana_data:/var/lib/grafana
    networks:
      - proxy
      - monitoring

  node-exporter:
    image: prom/node-exporter:latest
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
    networks:
      - monitoring

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks:
      - monitoring

networks:
  proxy:
    external: true
  monitoring:

volumes:
  prometheus_data:
  grafana_data:
```

Add to Caddyfile:

```caddyfile
grafana.example.com {
    reverse_proxy monitoring-grafana-1:3000
}
```

---

## Maintenance and Operations

### Common commands

```bash
# Start a project
cd /opt/infrastructure/saas-app
docker compose up -d

# Stop a project (keeps volumes/data)
docker compose down

# Destroy a project including data (CAUTION)
docker compose down -v

# Update a dependency image (e.g. upgrade Redis)
# 1. Change tag in docker-compose.yml (redis:7-alpine → redis:8-alpine)
# 2. Commit to Git, push
# 3. CI runs, or manually:
docker compose pull redis
docker compose up -d --no-deps redis

# View which containers are running
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Clean up unused images and build cache
docker system prune -af --volumes  # CAREFUL: removes unused volumes too
docker image prune -f              # safer: only dangling images
```

### Adding a new project

1. Create a new directory: `mkdir /opt/infrastructure/new-project`
2. Add a `docker-compose.yml` with the `proxy` external network on the web-facing service
3. Add the route to `caddy/Caddyfile`
4. Add a `deploy-new-project.yml` GitHub Actions workflow
5. Commit, push, done

### Rolling back a deployment

```bash
# Roll back to a specific image version (using the Git SHA tag)
cd /opt/infrastructure/saas-app
docker compose pull   # in case you need to re-fetch

# Or pin a specific version temporarily:
# Edit docker-compose.yml: image: ghcr.io/your-org/saas-app:abc123
docker compose up -d --no-deps app

# Or revert the Git commit and redeploy
git revert HEAD
git push   # triggers CI/CD
```

---

## Scaling Limits and Migration Path

This setup works well within these bounds:

| Resource      | Comfortable limit     | Signs you're outgrowing it                   |
| ------------- | --------------------- | -------------------------------------------- |
| RAM           | 8–12 GB               | `docker stats` shows consistent >85% usage   |
| CPU           | 4 vCPU                | Sustained high load during deploys or traffic |
| Projects      | 4–6 with dependencies | Running out of RAM for new services           |
| Disk          | Monitor with `df -h`  | Database volumes filling up                   |

### When you outgrow a single VPS

The migration path is clean because everything is already containerized:

1. **Split projects across VPS instances.** Move `saas-app/` to a larger VPS, keep lighter projects on the original. Update DNS.

2. **Docker Swarm.** Your existing compose files work with `docker stack deploy` with minimal changes (add `deploy:` keys for replicas and update strategies). Caddy or Traefik can discover services across the swarm.

3. **Managed services.** Move MySQL to a managed database (PlanetScale, RDS, Hetzner managed DB) and Redis to a managed cache. Your app containers stay the same — only the connection URLs in `.env` change.

---

## Quick Reference

```bash
# First-time setup
ssh root@your-vps
bash scripts/bootstrap.sh
cd /opt/infrastructure
docker compose -f caddy/docker-compose.yml up -d
docker compose -f saas-app/docker-compose.yml up -d
docker compose -f internal-tool/docker-compose.yml up -d
docker compose -f marketing-site/docker-compose.yml up -d

# Check everything is running
docker ps
curl -I https://saas.example.com      # should return 200
curl -I https://internal.example.com   # should return 200
curl -I https://example.com            # should return 200
```
