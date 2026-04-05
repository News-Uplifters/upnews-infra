# upnews-infra

Docker orchestration for running the UpNews stack locally.

## Overview

The UpNews platform consists of three services that must be cloned as **sibling directories**:

```
parent-dir/
├── upnews-api/          REST API (FastAPI, legacy Python + SQLite)
├── upnews-api-rust/     REST API (Axum, new Rust + Postgres)
├── upnews-pipeline/     News crawler + ML classifier
├── upnews-frontend/     React frontend (served by nginx)
└── upnews-infra/        ← this repo (docker-compose + scripts)
```

Each app repo contains its own `Dockerfile`. This repo's `docker-compose.yml` references them via relative build contexts and wires the services together.

Two parallel API stacks are available via docker-compose profiles. **Only one API profile should be active at a time** — both bind host port 8000.

| Profile   | API              | Database           | When to use                                              |
|-----------|------------------|--------------------|----------------------------------------------------------|
| `python`  | FastAPI (Python) | SQLite             | Maintain/test the legacy Python API                      |
| `rust`    | Axum (Rust)      | Postgres 16        | Develop/test the new Rust rewrite                        |

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

### Python stack (legacy — FastAPI + SQLite)

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

### Rust stack (new — Axum + Postgres)

```bash
# Clone all repos as siblings (upnews-api-rust instead of upnews-api)
git clone https://github.com/News-Uplifters/upnews-api-rust.git
git clone https://github.com/News-Uplifters/upnews-pipeline.git
git clone https://github.com/News-Uplifters/upnews-frontend.git
git clone https://github.com/News-Uplifters/upnews-infra.git

cd upnews-infra

# Build, start, crawl, validate — all in one go
./scripts/run-local-rust.sh
```

`run-local-rust.sh` will:
1. Tear down any previous Rust stack run (idempotent)
2. Check that Docker and all sibling repos are present
3. Build images in parallel (first Rust build takes 3–6 min for cargo-chef cache)
4. Start Postgres + Rust API + frontend
5. Poll `http://localhost:8000/api/health` until healthy
6. Run one pipeline crawl against Postgres
7. Validate that articles appear in the API and the frontend loads

## Manual commands

### Python stack

```bash
# Start API + frontend
docker compose --profile python up --build -d

# Run one pipeline crawl
docker compose --profile crawl run --rm pipeline

# Tail logs
docker compose logs -f api
docker compose logs -f frontend

# Stop and remove containers + volumes
docker compose --profile python down -v
```

### Rust stack

```bash
# Start Postgres + Rust API + frontend
docker compose --profile rust up --build -d

# Run one pipeline crawl (writes to Postgres)
docker compose --profile crawl-rust run --rm pipeline-rust

# Tail logs
docker compose logs -f api-rust
docker compose logs -f postgres

# Stop and remove containers + volumes
docker compose --profile rust down -v
```

## Environment variables

### Python stack (`--profile python`)

| Service  | Variable                    | Default (in compose)                              | Notes                                     |
|----------|-----------------------------|---------------------------------------------------|-------------------------------------------|
| api      | `DATABASE_DIR`              | `/app/data`                                       | API constructs DB path as `$DATABASE_DIR/upnews.db` |
| api      | `CORS_ORIGINS`              | `http://localhost,http://localhost:3000`           |                                           |
| api      | `LOG_LEVEL`                 | `INFO`                                            |                                           |
| pipeline | `DATABASE_PATH`             | `/app/data/upnews.db`                             | Must point to the shared volume           |
| pipeline | `CLASSIFIER_MODE`           | `rules`                                           | Use `setfit` if model weights are present |
| pipeline | `ARTICLES_LIMIT_PER_SOURCE` | `20`                                              | Keep low for fast local crawls            |
| frontend | `API_URL`                   | `/api`                                            | nginx proxies `/api/` to the API service  |

### Rust stack (`--profile rust`)

| Service       | Variable                    | Default (in compose)                              | Notes                                            |
|---------------|-----------------------------|---------------------------------------------------|--------------------------------------------------|
| api-rust      | `DATABASE_URL`              | `postgres://upnews:upnews@postgres:5432/upnews`   | Internal Postgres connection                     |
| api-rust      | `UPNEWS__HOST`              | `0.0.0.0`                                         |                                                  |
| api-rust      | `UPNEWS__PORT`              | `8000`                                            |                                                  |
| api-rust      | `UPNEWS__LOG_LEVEL`         | `info`                                            |                                                  |
| api-rust      | `UPNEWS__CORS_ORIGINS`      | `http://localhost,http://localhost:3000`           |                                                  |
| pipeline-rust | `DATABASE_URL`              | `postgres://upnews:upnews@postgres:5432/upnews`   | Pipeline writes directly to Postgres when set    |
| pipeline-rust | `ARTICLES_LIMIT_PER_SOURCE` | `20`                                              | Keep low for fast local crawls                   |

## Ports

| Service       | Profile  | Host port | Container port | Notes                         |
|---------------|----------|-----------|----------------|-------------------------------|
| api / api-rust| python/rust | 8000   | 8000           | Only one profile active at a time |
| postgres      | rust     | 5432      | 5432           | Rust stack only               |
| frontend      | python/rust | 3000   | 80             |                               |

## Useful endpoints

| URL                                    | Description                         |
|----------------------------------------|-------------------------------------|
| http://localhost:3000                  | Frontend (React SPA)                |
| http://localhost:8000/api/articles     | Articles JSON (both stacks)         |
| http://localhost:8000/api/health       | API health check (both stacks)      |
| http://localhost:8000/docs             | Interactive API docs (Python only)  |
| postgres://upnews:upnews@localhost:5432/upnews | Postgres (Rust stack only) |

## SetFit classifier (optional)

By default the pipeline uses a fast rule-based classifier (`CLASSIFIER_MODE=rules`).
To use the ML model, place the model weights at `../upnews-pipeline/models/setfit_uplifting_model/`
and change `CLASSIFIER_MODE` to `setfit` in `docker-compose.yml`.

## Cloud deployment

Cloud deployment (Fly.io, Render, GitHub Actions CI/CD) is out of scope for now.
Placeholder configs are in `deploy/` for future reference.
