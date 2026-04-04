# upnews-infra

Docker orchestration for running the UpNews stack locally.

## Overview

The UpNews platform consists of three services that must be cloned as **sibling directories**:

```
parent-dir/
├── upnews-api/          REST API (FastAPI)
├── upnews-pipeline/     News crawler + ML classifier
├── upnews-frontend/     React frontend (served by nginx)
├── upnews-inference/    ML inference microservice (Python + FastAPI + ONNX)
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

  Optional ML profile (--profile ml):
  └── upnews-inference :8001
        ├── POST /v1/classify    ← uplifting scorer
        ├── POST /v1/categorize  ← topic categoriser
        └── POST /v1/summarize   ← article summariser
              └── ONNX models (shared named volume: upnews-onnx-models)
                    └── consumed by pipeline via InferenceClient
```

- **API + Frontend** run as long-lived services.
- **Pipeline** runs on-demand via `--profile crawl` — it is not auto-started.
- **Inference service** runs on-demand via `--profile ml` — opt-in only, not required for a basic local stack.
- API and pipeline share the `upnews-data` named volume (SQLite DB).
- Inference service and pipeline share the `upnews-onnx-models` named volume (ONNX model files).

## Quick start

```bash
# Clone all repos as siblings
git clone https://github.com/News-Uplifters/upnews-api.git
git clone https://github.com/News-Uplifters/upnews-pipeline.git
git clone https://github.com/News-Uplifters/upnews-frontend.git
git clone https://github.com/News-Uplifters/upnews-inference.git
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
# Start API + frontend (default stack)
docker compose up --build -d

# Run one pipeline crawl (rule-based classifier, no inference service needed)
docker compose --profile crawl run --rm pipeline

# Start API + frontend + inference service (ML profile)
docker compose --profile ml up --build -d

# Run one pipeline crawl with the inference service
docker compose --profile ml --profile crawl run --rm pipeline

# Tail logs
docker compose logs -f api
docker compose logs -f frontend
docker compose logs -f inference      # only when --profile ml is active

# Stop and remove containers + volumes
docker compose down -v
```

## Environment variables

| Service   | Variable                    | Default (in compose)                              | Notes                                     |
|-----------|-----------------------------|---------------------------------------------------|-------------------------------------------|
| api       | `DATABASE_DIR`              | `/app/data`                                       | API constructs DB path as `$DATABASE_DIR/upnews.db` |
| api       | `CORS_ORIGINS`              | `http://localhost,http://localhost:3000`           |                                           |
| api       | `LOG_LEVEL`                 | `INFO`                                            |                                           |
| pipeline  | `DATABASE_PATH`             | `/app/data/upnews.db`                             | Must point to the shared volume           |
| pipeline  | `CLASSIFIER_MODE`           | `rules`                                           | Use `setfit` if model weights are present |
| pipeline  | `ARTICLES_LIMIT_PER_SOURCE` | `20`                                              | Keep low for fast local crawls            |
| pipeline  | `INFERENCE_SERVICE_URL`     | `http://upnews-inference:8001`                    | Empty = local fallback; set automatically when `--profile ml` is active |
| pipeline  | `INFERENCE_TIMEOUT_SEC`     | `30`                                              | HTTP timeout for calls to the inference service |
| frontend  | `API_URL`                   | `/api`                                            | nginx proxies `/api/` to the API service  |
| inference | `ORT_NUM_THREADS`           | `2`                                               | ONNX Runtime intra-op thread count        |
| inference | `CLASSIFIER_MODEL_PATH`     | `/app/onnx_models/uplifting_classifier`           | Path to uplifting classifier ONNX artifacts |
| inference | `CATEGORIZER_MODEL_PATH`    | `/app/onnx_models/topic_categorizer`              | Path to topic categoriser ONNX artifacts  |
| inference | `SUMMARIZER_MODEL_PATH`     | `/app/onnx_models/summarizer`                     | Path to DistilBART ONNX artifacts         |

## Ports

| Service   | Profile    | Host port | Container port |
|-----------|------------|-----------|----------------|
| api       | default    | 8000      | 8000           |
| frontend  | default    | 3000      | 80             |
| inference | `ml`       | 8001      | 8001           |

## Useful endpoints

| URL                                       | Profile    | Description                          |
|-------------------------------------------|------------|--------------------------------------|
| http://localhost:3000                     | default    | Frontend (React SPA)                 |
| http://localhost:8000/api/articles        | default    | Articles JSON                        |
| http://localhost:8000/api/health          | default    | API health check                     |
| http://localhost:8000/docs                | default    | Interactive API docs (Swagger)       |
| http://localhost:8001/health              | `ml`       | Inference service liveness           |
| http://localhost:8001/v1/models           | `ml`       | Per-model load status                |
| http://localhost:8001/docs                | `ml`       | Inference service API docs (Swagger) |

## SetFit classifier (optional)

By default the pipeline uses a fast rule-based classifier (`CLASSIFIER_MODE=rules`).
To use the ML model, place the model weights at `../upnews-pipeline/models/setfit_uplifting_model/`
and change `CLASSIFIER_MODE` to `setfit` in `docker-compose.yml`.

## Inference service (optional — `--profile ml`)

The `upnews-inference` service runs the three ML models (uplifting classifier, topic categoriser, DistilBART summariser) as a persistent warm-model microservice. This eliminates the 10–30 second model cold-start on every pipeline run.

### Prerequisites

1. Clone `upnews-inference` as a sibling directory
2. Run the ONNX export scripts to generate model artifacts:
   ```bash
   cd ../upnews-inference
   pip install -r requirements-export.txt
   python scripts/export_setfit_to_onnx.py \
     --model-dir ../upnews-pipeline/models/setfit_uplifting_model \
     --output-dir onnx_models/uplifting_classifier
   python scripts/export_setfit_to_onnx.py \
     --model-dir ../upnews-pipeline/models/setfit_topic_model \
     --output-dir onnx_models/topic_categorizer
   python scripts/export_distilbart_to_onnx.py \
     --output-dir onnx_models/summarizer
   ```
3. Start the full stack with the `ml` profile:
   ```bash
   docker compose --profile ml up --build -d
   docker compose --profile ml --profile crawl run --rm pipeline
   ```

The pipeline's `INFERENCE_SERVICE_URL` is set automatically in compose when the `ml` profile is active. If the inference service is unreachable, the pipeline falls back to the local rule-based classifier transparently.

See [upnews-inference](https://github.com/News-Uplifters/upnews-inference) for full documentation.

## Cloud deployment

Cloud deployment (Fly.io, Render, GitHub Actions CI/CD) is out of scope for now.
Placeholder configs are in `deploy/` for future reference.
See [upnews-inference/docs/aws-fargate-deployment.md](https://github.com/News-Uplifters/upnews-inference/blob/main/docs/aws-fargate-deployment.md) for the inference service Fargate deployment guide.
