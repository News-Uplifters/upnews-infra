# UpNews Infrastructure & Deployment

Production-ready infrastructure, Docker containers, CI/CD pipelines, and deployment configurations for the UpNews platform.

## Project Description

UpNews Infrastructure contains all containerization, orchestration, continuous integration, and deployment configurations for the UpNews platform. This repo manages:

- **Docker containers** for three core services (API, Pipeline, Frontend)
- **CI/CD pipelines** using GitHub Actions for automated testing and building
- **Deployment templates** for Fly.io, Render, and Cloudflare Pages
- **Infrastructure-as-Code** for reproducible deployments
- **Monitoring and alerting** configurations

## Architecture Overview

The UpNews platform is deployed as three containerized services:

```
┌─────────────────────────────────────────────────────┐
│                   End Users                          │
└────────────────────┬────────────────────────────────┘
                     │
         ┌───────────┴───────────┐
         │                       │
    ┌────▼─────────┐     ┌──────▼──────────┐
    │  Cloudflare  │     │  REST API       │
    │  Pages CDN   │     │  (upnews-api)   │
    │  (Frontend)  │     │  Port 8000      │
    └──────────────┘     └────────┬────────┘
                                  │
                         ┌────────┴────────┐
                         │                 │
                    ┌────▼──────────┐  ┌──▼───────────────┐
                    │ SQLite DB     │  │ News Pipeline    │
                    │ (Turso/Local) │  │ (upnews-pipeline)│
                    └───────────────┘  │ Runs every 4h    │
                                       └──────────────────┘
```

**Services:**

1. **upnews-api** — Python FastAPI REST backend, processes requests, queries news database
2. **upnews-pipeline** — Python ML pipeline, crawls feeds, performs topic modeling, writes to database
3. **upnews-frontend** — Node.js React app, served via Nginx, deployed to Cloudflare Pages

**Storage:**

- **SQLite Database** — Local file-based (docker-compose) or edge-hosted on Turso
- **Shared volume** — Docker mounts for persistent database across service restarts

## Cost Estimate

Approximate monthly cost for full UpNews deployment (single region, development tier):

| Component | Provider | Cost | Notes |
|-----------|----------|------|-------|
| API & Pipeline Hosting | Fly.io | $0.50 | Shared-cpu-1x, 256MB RAM |
| Database | Turso (free tier) | $0 | Edge SQLite, generous free quota |
| Frontend CDN | Cloudflare Pages | $0 | Free tier with unlimited sites |
| Monitoring | Uptime checks | $0–2 | Free via UptimeRobot or similar |
| **Total** | | **$0.50–6/mo** | Scales to $20–50/mo at production scale |

*See deployment guides below for cost optimization strategies.*

---

## TODO Task List for Contributors / Claude Agents

This is the central roadmap for completing the UpNews infrastructure. Each task is self-contained and can be worked on independently (with noted dependencies). Tasks are in recommended dependency order.

### TASK 1: Create Dockerfile for upnews-api

**File:** `docker/api.Dockerfile`

Build a production Python 3.11 slim image for the FastAPI REST service.

**Requirements:**
- Base image: `python:3.11-slim`
- Copy `requirements.txt` and install dependencies with `pip` (no caching)
- Copy application code
- Expose port 8000
- CMD runs: `uvicorn app.main:app --host 0.0.0.0 --port 8000`
- Health check endpoint: `/health` (verify API is alive)

**Dependencies:** None (independent)

---

### TASK 2: Create Dockerfile for upnews-pipeline

**File:** `docker/pipeline.Dockerfile`

Build a Python 3.11 image for the ML-heavy pipeline service (heavier deps: numpy, scikit-learn, spacy).

**Requirements:**
- Base image: `python:3.11` (full, not slim — ML libraries need dev tools)
- Copy `requirements.txt` and install dependencies (same as api, plus ML: numpy, scikit-learn, transformers, etc.)
- Copy application code
- No exposed ports (runs as cron/batch job)
- CMD runs: `python -m upnews_pipeline.crawl` (entry point for pipeline job)
- Environment variable: `DATABASE_URL` (SQLite path or Turso connection string)

**Dependencies:** None (independent)

---

### TASK 3: Create Dockerfile for upnews-frontend

**File:** `docker/frontend.Dockerfile`

Build a multi-stage image: Node build stage → slim Nginx serve stage.

**Requirements:**
- **Stage 1 (build):** `node:18-alpine` → `npm ci && npm run build` → output to `/app/dist`
- **Stage 2 (serve):** `nginx:alpine` → copy `/app/dist` to `/usr/share/nginx/html` → copy custom nginx.conf
- Expose port 80
- CMD: `nginx -g "daemon off;"`
- Nginx should proxy API requests to `http://api:8000` (for docker-compose)

**Dependencies:** TASK 4 (docker-compose must reference this) but build is independent.

---

### TASK 4: Create docker-compose.yml

**File:** `docker-compose.yml`

Orchestrate all 3 services + SQLite persistence.

**Requirements:**
- Service `api`: Build from `docker/api.Dockerfile`, port `8000:8000`, environment vars from `.env`
- Service `pipeline`: Build from `docker/pipeline.Dockerfile`, environment vars from `.env`, depends on `api`
- Service `frontend`: Build from `docker/frontend.Dockerfile`, port `80:80`, depends on `api`
- Volume `db`: SQLite database file (persistent)
- All services can resolve each other by hostname (e.g., `http://api:8000`)
- Health checks defined for `api` (via `/health` endpoint)

**Dependencies:** TASK 1, 2, 3 (Dockerfiles must exist)

---

### TASK 5: Create GitHub Actions CI workflow for upnews-api

**File:** `.github/workflows/ci-api.yml`

Automated testing and building for the API service.

**Requirements:**
- Trigger: `push` and `pull_request` on paths `api/**`, `docker/api.Dockerfile`, `.github/workflows/ci-api.yml`
- Steps:
  1. Checkout code
  2. Set up Python 3.11
  3. Install dependencies: `pip install -r api/requirements.txt -r api/requirements-dev.txt`
  4. Lint with `ruff check api/`
  5. Format check with `ruff format --check api/`
  6. Run tests: `pytest api/tests/` (with coverage if available)
  7. Build Docker image: `docker build -f docker/api.Dockerfile -t upnews-api:latest .`
- Fail workflow if any step fails
- Optional: Upload coverage reports to Codecov

**Dependencies:** None (independent CI config)

---

### TASK 6: Create GitHub Actions CI workflow for upnews-frontend

**File:** `.github/workflows/ci-frontend.yml`

Automated testing, linting, and building for the frontend.

**Requirements:**
- Trigger: `push` and `pull_request` on paths `frontend/**`, `docker/frontend.Dockerfile`, `.github/workflows/ci-frontend.yml`
- Steps:
  1. Checkout code
  2. Set up Node 18
  3. Install deps: `npm ci` (from `frontend/`)
  4. Lint with `eslint`
  5. Build: `npm run build`
  6. (Optional) Lighthouse CI for performance checks
  7. Build Docker image: `docker build -f docker/frontend.Dockerfile -t upnews-frontend:latest .`
- Fail if linting or build fails

**Dependencies:** None (independent CI config)

---

### TASK 7: Create GitHub Actions CI workflow for upnews-pipeline

**File:** `.github/workflows/ci-pipeline.yml`

Automated testing for the ML pipeline.

**Requirements:**
- Trigger: `push` and `pull_request` on paths `pipeline/**`, `docker/pipeline.Dockerfile`, `.github/workflows/ci-pipeline.yml`
- Steps:
  1. Checkout code
  2. Set up Python 3.11
  3. Install dependencies: `pip install -r pipeline/requirements.txt -r pipeline/requirements-dev.txt`
  4. Lint with `ruff check pipeline/`
  5. Test with `pytest pipeline/tests/` (mock feed tests, no real API calls)
  6. Build Docker image: `docker build -f docker/pipeline.Dockerfile -t upnews-pipeline:latest .`
- All tests must use mock data (no external API dependencies)

**Dependencies:** None (independent CI config)

---

### TASK 8: Create scheduled GitHub Action to run the pipeline every 4 hours

**File:** `.github/workflows/scheduled-crawl.yml`

Automated news crawl execution via GitHub Actions.

**Requirements:**
- Trigger: `schedule` with cron expression `0 */4 * * *` (every 4 hours UTC)
- Manual trigger option: `workflow_dispatch`
- Steps:
  1. Checkout code
  2. Build pipeline Docker image
  3. Run pipeline container: `docker run --rm --env-file .env upnews-pipeline:latest`
  4. Connect to production database (Turso or cloud SQLite)
  5. Log success/failure
- Environment variables: Load from GitHub Secrets (`TURSO_URL`, `TURSO_TOKEN`, etc.)
- Retry logic: On failure, retry once after 5 minutes

**Dependencies:** TASK 2 (pipeline Dockerfile), TASK 11 (Turso setup) or cloud database

---

### TASK 9: Create deployment config for Fly.io or Render (cheapest option)

**File:** `deploy/fly.toml` OR `deploy/render.yaml`

Infrastructure-as-Code config for serverless/container deployment.

**Requirements (Fly.io):**
- App name: `upnews-platform`
- Region: `iad` (or cheapest available)
- Processes: `web` (API + frontend), separate cron job for pipeline
- Health checks: HTTP GET `/health` (api service)
- Env vars: Reference `TURSO_URL`, `DATABASE_URL`, etc.
- Scale: 1 shared-cpu instance, 256MB RAM
- Volume: Persistent storage for SQLite (if not using Turso)

**OR Render (alternative):**
- Create `render.yaml` blueprint with services for API, pipeline (cron), and frontend
- Web service with health check
- Cron job service for pipeline (runs every 4 hours)
- Env var groups for secrets

**Dependencies:** TASK 4 (docker-compose base), TASK 11 (if using Turso)

---

### TASK 10: Set up Cloudflare Pages deployment for frontend

**File:** `deploy/cloudflare-pages.md` (documentation)

Instructions and configuration for deploying frontend to Cloudflare Pages CDN.

**Requirements:**
- Document the setup steps:
  1. Connect GitHub repo to Cloudflare Pages
  2. Configure build command: `cd frontend && npm run build`
  3. Build output: `frontend/dist`
  4. Environment variables: `REACT_APP_API_URL` (production API endpoint)
  5. Auto-deploy on push to `main` branch
- Include routing rules (rewrite SPA routes to `index.html`)
- Document custom domain setup
- Add to GitHub Actions: trigger Cloudflare Pages deployment on successful frontend build

**Dependencies:** TASK 6 (frontend CI)

---

### TASK 11: Create Turso (edge SQLite) setup script as alternative to local SQLite

**File:** `deploy/turso-setup.sh` and `deploy/turso-env.example`

Script to provision Turso database and generate connection strings.

**Requirements:**
- Bash script to:
  1. Check for `turso` CLI installation
  2. Authenticate with Turso API
  3. Create a new database (e.g., `upnews-db`)
  4. Copy schema from local SQLite (migrate existing DB)
  5. Generate `TURSO_URL` and `TURSO_TOKEN` environment variables
  6. Output to `.env` file
- Document the free tier limits (up to 500 requests/month on free, scales to $29/mo)
- Provide rollback instructions

**Dependencies:** None (independent setup)

---

### TASK 12: Add monitoring/alerting (uptime check, crawl health endpoint)

**File:** `deploy/monitoring.md` and optional `.github/workflows/health-check.yml`

Configuration for uptime monitoring and health checks.

**Requirements:**
- Document setup for free monitoring services (UptimeRobot, Healthchecks.io, etc.)
- Uptime check: GET `/health` endpoint on api service (every 5 min)
- Crawl health: POST to Healthchecks.io on pipeline success
  - If pipeline fails, alert via email/Slack
  - Include last crawl timestamp in response
- Create optional GitHub Actions workflow: `.github/workflows/health-check.yml`
  - Runs every 10 minutes
  - Calls `/health` endpoint
  - Fails workflow if API unreachable
- Document alerting channels (email, Slack webhook)

**Dependencies:** TASK 9 (deployment) and TASK 5 (API health endpoint)

---

## Deployment Guides

### Option A: Deploy to Fly.io (Recommended for Cost)

1. **Install Fly CLI:** `brew install flyctl`
2. **Authenticate:** `flyctl auth login`
3. **Deploy:** `flyctl deploy -c deploy/fly.toml`
4. **Database:** Use Turso (TASK 11) for edge SQLite
5. **Cost:** ~$0.50/mo for shared CPU instance
6. **Monitoring:** Built-in status dashboard at `fly.io/dashboard`

### Option B: Deploy to Render

1. **Create Render account** at render.com
2. **Connect GitHub repo:** Authorize Render to access your repo
3. **Deploy blueprint:** Push `render.yaml` to repo root
4. **Render auto-deploys:** On push to `main` branch
5. **Cost:** ~$7/mo for basic web service + cron
6. **Database:** Use Turso or Render Postgres (Postgres is $15/mo, skip it)

### Option C: Local Development (docker-compose)

1. **Prerequisites:** Docker, Docker Compose installed
2. **Run all services:** `docker-compose up`
3. **Database:** SQLite in Docker volume (persists across restarts)
4. **API endpoint:** http://localhost:8000
5. **Frontend:** http://localhost:80
6. **Stop:** `docker-compose down`

### Frontend: Deploy to Cloudflare Pages (Free)

1. **Connect GitHub repo** at pages.cloudflare.com
2. **Configure:**
   - Build command: `cd frontend && npm run build`
   - Build output: `frontend/dist`
3. **Environment:** Set `REACT_APP_API_URL` to your production API
4. **Auto-deploy:** On every push to `main`
5. **Custom domain:** Use your own domain (DNS CNAME)
6. **Cost:** Free with unlimited sites

---

## Environment Variables Reference

Copy `.env.example` to `.env` and fill in values:

```bash
# Database
DATABASE_URL=sqlite:///./upnews.db              # Local (docker-compose)
TURSO_URL=libsql://your-db.turso.io             # Turso (production)
TURSO_TOKEN=your-auth-token                     # Turso auth

# API Service
API_PORT=8000
API_HOST=0.0.0.0
LOG_LEVEL=info

# Pipeline Service
CRAWL_INTERVAL_HOURS=4
ML_MODEL=distilbert-base-uncased                # Hugging Face model
MAX_ARTICLES_PER_FEED=50

# Frontend
REACT_APP_API_URL=http://localhost:8000         # Local
REACT_APP_API_URL=https://api.upnews.com        # Production

# Monitoring
HEALTHCHECKS_IO_URL=https://hc-ping.com/your-id
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
```

---

## File Structure

```
upnews-infra/
├── README.md                           # This file
├── .gitignore
├── .env.example
├── docker/
│   ├── api.Dockerfile
│   ├── pipeline.Dockerfile
│   └── frontend.Dockerfile
├── docker-compose.yml
├── .github/
│   └── workflows/
│       ├── ci-api.yml
│       ├── ci-frontend.yml
│       ├── ci-pipeline.yml
│       ├── scheduled-crawl.yml
│       └── health-check.yml
├── deploy/
│   ├── fly.toml
│   ├── render.yaml
│   ├── cloudflare-pages.md
│   ├── turso-setup.sh
│   ├── turso-env.example
│   └── monitoring.md
└── nginx/
    └── nginx.conf
```

---

## Quick Start

```bash
# Clone and setup
git clone https://github.com/News-Uplifters/upnews-infra.git
cd upnews-infra

# Local development
cp .env.example .env
docker-compose up

# Tests run in CI (GitHub Actions)
# See .github/workflows/ for pipeline definitions

# Deploy to Fly.io
flyctl deploy -c deploy/fly.toml
```

---

## Contributing

All tasks in the TODO list above are open for contribution. Pick a task, follow its requirements, and submit a PR.

For questions or blockers, create an issue or discuss in #infrastructure channel.

---

## License

MIT License — See LICENSE file in main UpNews repo.
