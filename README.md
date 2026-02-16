# Solo-Stack

A maintainable, version-trackable setup for running multiple containerized services on a single Ubuntu VPS.

**Stack:** Docker Compose, Caddy (reverse proxy + automatic TLS), GitHub Actions (CI/CD), GitHub Container Registry (ghcr.io)

## The Problem

You have a handful of projects — a SaaS app, an internal tool, a marketing site — and you want to run them all on one affordable VPS. But managing multiple services by hand leads to:

- Snowflake servers with undocumented manual changes
- No reproducibility — if the VPS dies, you're rebuilding from memory
- Messy TLS certificate management with certbot cron jobs
- Services interfering with each other's dependencies
- No clear deployment pipeline

## The Solution

Solo-Stack gives you a single Git repository that defines your entire server. Every piece of config is a file you can review, version, and redeploy. Each project is an isolated Docker Compose stack with its own dependencies. A single Caddy instance handles TLS and routing.

```
                    Internet
                       |
                 +-----+-----+
                 |   Caddy    |  <- automatic Let's Encrypt TLS
                 |  :80 :443  |
                 +--+---+---+-+
                    |   |   |
            +-------+   |   +-------+
            |           |           |
    +-------+--+  +-----+----+  +--+----------+
    | saas-app |  | internal  |  |  marketing  |
    |   :8000  |  |   :3000   |  |    :80      |
    +---+------+  +----+------+  +-------------+
        |              |
   +----+----+    +----+----+
   | mysql   |    |  redis  |    <- isolated backend networks
   | redis   |    +---------+      not reachable by other projects
   | meili   |
   +---------+
```

**Key principles:**

- The `proxy` network is the only shared Docker network. Only web-facing app containers join it.
- Each project's backing services live on a private `backend` network, unreachable by Caddy or other projects.
- Every piece of config is a file in Git. No GUI-driven state, no manual server changes.
- Each project deploys independently via its own GitHub Actions workflow.

## Repository Structure

```
solo-stack/
├── README.md
├── .gitignore
├── caddy/
│   ├── docker-compose.yml       # Caddy reverse proxy
│   └── Caddyfile                # Route definitions (edit per project)
├── backups/
│   ├── docker-compose.yml       # offen/docker-volume-backup
│   └── .env.example             # S3 credentials, schedule, retention
├── scripts/
│   ├── bootstrap.sh             # One-time VPS provisioning
│   └── deploy.sh                # Generic deploy helper
└── .github/
    └── workflows/
        ├── deploy-caddy.yml               # Reload Caddy on config push
        ├── deploy-template.yml            # For custom apps you build
        └── deploy-thirdparty-template.yml # For cloned third-party repos
```

Project directories (e.g., `saas-app/`, `internal-tool/`) are created by you when you add services. See [Adding a New Project](#adding-a-new-project) below.

## Quick Start

### 1. Provision the VPS

SSH into a fresh Ubuntu 24.04 VPS as root and run the bootstrap script:

```bash
curl -fsSL https://raw.githubusercontent.com/reneweiser/solo-stack/main/scripts/bootstrap.sh | bash
```

Or clone first and run locally:

```bash
git clone https://github.com/reneweiser/solo-stack.git /opt/solo-stack
cd /opt/solo-stack
sudo bash scripts/bootstrap.sh
```

This installs Docker, creates a `deploy` user, sets up UFW firewall rules, and creates the shared `proxy` network.

### 2. Start Caddy

```bash
cd /opt/solo-stack/caddy
# Edit Caddyfile — uncomment and update domains for your projects
docker compose up -d
```

### 3. Deploy a project

Create a project directory, add a `docker-compose.yml` (see examples below), and start it:

```bash
cd /opt/solo-stack
mkdir saas-app && cd saas-app
# Add docker-compose.yml and .env
docker compose up -d
```

### 4. Set up backups

```bash
cd /opt/solo-stack/backups
cp .env.example .env
# Fill in S3 credentials and schedule
docker compose up -d
```

## Adding a Custom Project

For apps you build and push to a container registry (GHCR, Docker Hub, etc.):

1. Create a directory: `mkdir /opt/solo-stack/my-project`
2. Add a `docker-compose.yml` — web-facing services join the `proxy` network, backing services stay on a private `backend` network
3. Add the route to `caddy/Caddyfile`
4. Copy `.github/workflows/deploy-template.yml` to `.github/workflows/deploy-my-project.yml` and replace `PROJECT_NAME` with your directory name
5. Commit, push, done

## Adding a Third-Party Project

Many open-source projects ship their own `docker-compose.yml` in a repo you clone (e.g., [Zammad](https://github.com/zammad/zammad-docker-compose), [Plausible](https://github.com/plausible/community-edition), [Gitea](https://github.com/go-gitea/gitea)). You don't build anything — you just configure and run.

The key trick: use `docker-compose.override.yml` to connect them to your Caddy proxy network without editing their compose file. Docker Compose automatically merges both files, so `git pull` to get upstream updates stays clean.

### Step by step

1. **Clone the project** into your solo-stack directory on the VPS:

    ```bash
    cd /opt/solo-stack
    git clone https://github.com/zammad/zammad-docker-compose.git zammad
    ```

2. **Create a `docker-compose.override.yml`** to connect the web-facing service to the proxy network and remove the exposed host port (Caddy handles that):

    ```yaml
    # /opt/solo-stack/zammad/docker-compose.override.yml
    services:
      zammad-nginx:
        ports: !reset []
        networks:
          - default
          - proxy

    networks:
      proxy:
        external: true
    ```

    > Find the web-facing service by looking for the one with `ports:` in their compose file. That's the service Caddy should route to.

3. **Configure the project** — copy their `.env.example` to `.env` and fill in values as their docs describe.

4. **Add the route to `caddy/Caddyfile`:**

    ```caddyfile
    support.example.com {
        reverse_proxy zammad-zammad-nginx-1:8080
    }
    ```

    > The container name follows the pattern `{directory}-{service}-{n}`. The internal port is whatever the service listens on (check their compose file — Zammad's nginx uses `8080`).

5. **Start it:**

    ```bash
    cd /opt/solo-stack/zammad
    docker compose up -d
    ```

6. **For CI/CD**, copy `.github/workflows/deploy-thirdparty-template.yml` and replace `PROJECT_NAME` with your directory name. This gives you a manual trigger button in GitHub Actions and an optional weekly auto-update schedule.

### Updating a third-party project

```bash
cd /opt/solo-stack/zammad
git pull                    # get upstream compose changes
docker compose pull         # pull new images
docker compose up -d        # recreate with new images
docker image prune -f       # clean up old images
```

Your `docker-compose.override.yml` is untracked by the upstream repo, so it survives `git pull` without conflicts.

## Example Compose Files

These are complete, copy-paste examples for common project types. Create the directory and save the compose file to get started.

### SaaS App (MySQL + Redis + Meilisearch)

<details>
<summary><code>saas-app/docker-compose.yml</code></summary>

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
      - proxy
      - backend

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
      - backend
    labels:
      # Back up MySQL via docker-volume-backup pre-hook
      - docker-volume-backup.archive-pre=/bin/sh -c 'mysqldump -u root -p"$$MYSQL_ROOT_PASSWORD" --all-databases > /backup/dump.sql'

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

volumes:
  mysql_data:
  redis_data:
  meili_data:
```

</details>

<details>
<summary><code>saas-app/.env.example</code></summary>

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

</details>

### Internal Tool (Redis)

<details>
<summary><code>internal-tool/docker-compose.yml</code></summary>

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

</details>

### Marketing Site (static, no dependencies)

<details>
<summary><code>marketing-site/docker-compose.yml</code></summary>

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

</details>

## Backups

Backups use [offen/docker-volume-backup](https://github.com/offen/docker-volume-backup) — a lightweight container that backs up Docker volumes on a cron schedule.

It supports:
- **Scheduled backups** via cron expression
- **S3-compatible upload** (AWS, Backblaze B2, MinIO, Wasabi)
- **Pre-backup hooks** via container labels (e.g., `mysqldump` before archiving)
- **Stop-during-backup** labels for data consistency
- **Retention pruning** to auto-delete old backups
- **Notifications** via webhook on success/failure

To opt a service into backups, add labels to its container in its own compose file:

```yaml
labels:
  # Run a command before backup (e.g., database dump)
  - docker-volume-backup.archive-pre=/bin/sh -c 'mysqldump -u root -p"$$MYSQL_ROOT_PASSWORD" --all-databases > /backup/dump.sql'
  # Stop this container during backup for data consistency
  - docker-volume-backup.stop-during-backup=true
```

Then mount the relevant volumes in `backups/docker-compose.yml`.

## CI/CD

Each project gets its own GitHub Actions workflow. Two templates are provided:

- **`deploy-template.yml`** — for custom apps you build and push to GHCR. Triggers on pushes to the project directory.
- **`deploy-thirdparty-template.yml`** — for third-party projects you clone. Triggers manually or on a weekly schedule to pull upstream updates.

**Required GitHub secrets:**

| Secret | Description |
|--------|-------------|
| `VPS_HOST` | VPS IP or Tailscale hostname |
| `VPS_SSH_KEY` | SSH private key for `deploy` user |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID (if using Tailscale) |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret (if using Tailscale) |

## Environment Variables

**Rule: `.env` files never enter Git.** Only `.env.example` (with placeholder values) is committed. On the server, `.env` files are created once and updated manually or via CI secrets.

## Common Operations

```bash
# Start a project
cd /opt/solo-stack/saas-app && docker compose up -d

# Stop a project (keeps volumes/data)
docker compose down

# Update a single service image
docker compose pull app && docker compose up -d --no-deps app

# View running containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Follow logs
docker compose logs -f app

# Clean up unused images
docker image prune -f
```
