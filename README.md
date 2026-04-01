# upnews-infra

Docker orchestration for running the UpNews stack locally.

## Overview

The UpNews platform consists of three services that must be cloned as **sibling directories**:

```
parent-dir/
├── upnews-api/          REST API (FastAPI)
├── upnews-pipeline/     News crawler + ML classifier
├── upnews-frontend/     React frontend (served by nginx)
└── upnews-infra/        ← this repo (docker-compose + scripts)
```

Each app repo contains its own `Dockerfile`. This repo's `docker-compose.yml` references them via relative build contexts and wires the services together.

## Architecture

```
Browser
  └── http://localhost:3000
        └── nginx (frontend container)
              ├── /          → serves React SPA (static files)
              └── /api/      → proxies to api:8000 (via "backend" alias)
                                  └── SQLite DB (shared named volume: upnews-data)
                                        └── written by pipeline (on-demand)
```

- **API + Frontend** run as long-lived services.
- **Pipeline** runs on-demand via `--profile crawl` — it is not auto-started.
- Both API and pipeline share the `upnews-data` named volume so they read/write the same SQLite database.

## Quick start

```bash
# Clone all repos as siblings
git clone https://github.com/News-Uplifters/upnews-api.git
git clone https://github.com/News-Uplifters/upnews-pipeline.git
git clone https://github.com/News-Uplifters/upnews-frontend.git
git clone https://github.com/News-Uplifters/upnews-infra.git

cd upnews-infra

# Build, start, crawl, validate — all in one go
./scripts/run-local.sh
```

`run-local.sh` will:
1. Check that Docker and all sibling repos are present
2. Build all images in parallel
3. Start the API and frontend
4. Wait for the API health check to pass
5. Run one pipeline crawl
6. Validate that articles appear in the API and the frontend loads

## Manual commands

```bash
# Start API + frontend
docker compose up --build -d

# Run one pipeline crawl
docker compose --profile crawl run --rm pipeline

# Tail logs
docker compose logs -f api
docker compose logs -f frontend

# Stop and remove containers + volume
docker compose down -v
```

## Environment variables

| Service  | Variable                    | Default (in compose)                              | Notes                                     |
|----------|-----------------------------|---------------------------------------------------|-------------------------------------------|
| api      | `DATABASE_DIR`              | `/app/data`                                       | API constructs DB path as `$DATABASE_DIR/upnews.db` |
| api      | `CORS_ORIGINS`              | `http://localhost,http://localhost:3000`           |                                           |
| api      | `LOG_LEVEL`                 | `INFO`                                            |                                           |
| pipeline | `DATABASE_PATH`             | `/app/data/upnews.db`                             | Must point to the shared volume           |
| pipeline | `CLASSIFIER_MODE`           | `rules`                                           | Use `setfit` if model weights are present |
| pipeline | `ARTICLES_LIMIT_PER_SOURCE` | `20`                                              | Keep low for fast local crawls            |
| frontend | `API_URL`                   | `/api`                                            | nginx proxies `/api/` to the API service  |

## Ports

| Service  | Host port | Container port |
|----------|-----------|----------------|
| api      | 8000      | 8000           |
| frontend | 3000      | 80             |

## Useful endpoints

| URL                                    | Description               |
|----------------------------------------|---------------------------|
| http://localhost:3000                  | Frontend (React SPA)      |
| http://localhost:8000/api/articles     | Articles JSON             |
| http://localhost:8000/api/health       | API health check          |
| http://localhost:8000/docs             | Interactive API docs      |

## SetFit classifier (optional)

By default the pipeline uses a fast rule-based classifier (`CLASSIFIER_MODE=rules`).
To use the ML model, place the model weights at `../upnews-pipeline/models/setfit_uplifting_model/`
and change `CLASSIFIER_MODE` to `setfit` in `docker-compose.yml`.

## Cloud deployment

Cloud deployment (Fly.io, Render, GitHub Actions CI/CD) is out of scope for now.
Placeholder configs are in `deploy/` for future reference.
