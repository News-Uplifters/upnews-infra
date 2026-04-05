#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# UpNews Local E2E — Rust API + Postgres
#
# Builds and starts the new Rust stack (Axum + Postgres + frontend),
# runs one pipeline crawl (Postgres variant), and validates that
# articles appear in the API.
#
# Prerequisites:
#   - Docker + Docker Compose v2
#   - All repos cloned as siblings:
#
#   parent-dir/
#   ├── upnews-api-rust/     <-- new Rust API
#   ├── upnews-pipeline/
#   ├── upnews-frontend/
#   └── upnews-infra/        <-- run this script from here
#
# Use scripts/run-local.sh for the legacy Python + SQLite stack.
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$INFRA_DIR")"

cd "$INFRA_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

# ── Preflight checks ────────────────────────────────────────

info "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    fail "docker not found. Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker compose version &>/dev/null 2>&1; then
    fail "docker compose v2 not found. Update Docker Desktop or install the compose plugin."
    exit 1
fi

MISSING=()
for repo in upnews-api-rust upnews-pipeline upnews-frontend; do
    if [ ! -d "${PARENT_DIR}/${repo}" ]; then
        MISSING+=("$repo")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    fail "Missing sibling repos: ${MISSING[*]}"
    echo "  Expected layout:"
    echo "    $(basename "$PARENT_DIR")/"
    echo "    ├── upnews-api-rust/"
    echo "    ├── upnews-pipeline/"
    echo "    ├── upnews-frontend/"
    echo "    └── upnews-infra/  <-- you are here"
    echo ""
    echo "  Clone any missing repos from https://github.com/News-Uplifters"
    exit 1
fi

ok "All prerequisites met."
echo ""

# ── Step 1: Build images ─────────────────────────────────────

info "[1/5] Building images (first Rust build can take 3–6 min for cargo-chef cache)..."
docker compose --profile rust build --parallel
echo ""

# ── Step 2: Start Postgres + Rust API + Frontend ─────────────

info "[2/5] Starting Postgres + Rust API + Frontend..."
docker compose --profile rust up -d
echo ""

# ── Step 3: Wait for API health (from host, distroless has no shell) ──

info "[3/5] Waiting for /api/health to respond..."
MAX_WAIT=60
HEALTHY=0
for i in $(seq 1 $MAX_WAIT); do
    if curl -sf http://localhost:8000/api/health >/dev/null 2>&1; then
        ok "API is healthy (took ${i}s)"
        HEALTHY=1
        break
    fi
    printf "  waiting... (%ds)\r" "$i"
    sleep 1
done

if [ "$HEALTHY" -ne 1 ]; then
    fail "API did not become healthy within ${MAX_WAIT}s"
    echo ""
    echo "── api-rust logs ──"
    docker compose logs api-rust --tail 40
    echo ""
    echo "── postgres logs ──"
    docker compose logs postgres --tail 20
    exit 1
fi

API_RESP=$(curl -sf http://localhost:8000/api/health 2>/dev/null || echo "")
echo "  Response: $API_RESP"
echo ""

# ── Step 4: Run the pipeline (Postgres variant) ──────────────

info "[4/5] Running pipeline crawl against Postgres..."
echo "  This takes 1–3 minutes on first run."
echo ""

if docker compose --profile crawl-rust run --rm pipeline-rust 2>&1 | tee /tmp/upnews-pipeline-rust.log | tail -20; then
    ok "Pipeline completed successfully"
else
    PIPELINE_EXIT=$?
    warn "Pipeline exited with code $PIPELINE_EXIT"
    echo "  Full log: /tmp/upnews-pipeline-rust.log"
    echo "  (Continuing — some articles may have been stored despite the error)"
fi
echo ""

# ── Step 5: Validate end-to-end ──────────────────────────────

info "[5/5] Validating end-to-end..."

ARTICLES_JSON=$(curl -sf 'http://localhost:8000/api/articles?page=1&limit=20' 2>/dev/null || echo "")
ARTICLE_COUNT=0
if [ -n "$ARTICLES_JSON" ]; then
    ARTICLE_COUNT=$(echo "$ARTICLES_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Rust API returns FLAT shape: {articles, page, limit, total, total_pages}
    if 'total' in data:
        print(data['total'])
    elif 'articles' in data and isinstance(data['articles'], list):
        print(len(data['articles']))
    elif 'data' in data and isinstance(data['data'], list):
        print(len(data['data']))
    else:
        print(0)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
fi

FRONTEND_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:3000/ 2>/dev/null || echo "000")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$ARTICLE_COUNT" -gt 0 ] && [ "$FRONTEND_STATUS" = "200" ]; then
    echo -e "${GREEN}  END-TO-END TEST PASSED (Rust stack)${NC}"
else
    echo -e "${YELLOW}  PARTIAL SUCCESS (Rust stack)${NC}"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Stack:           Rust Axum + Postgres 16"
echo "  Articles in DB:  $ARTICLE_COUNT"
echo "  Frontend HTTP:   $FRONTEND_STATUS"
echo ""
echo "  Frontend:        http://localhost:3000"
echo "  API:             http://localhost:8000/api/articles"
echo "  API health:      http://localhost:8000/api/health"
echo "  Postgres:        postgres://upnews:upnews@localhost:5432/upnews"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Useful commands:"
echo "    docker compose logs api-rust                                # Rust API logs"
echo "    docker compose logs postgres                                # Postgres logs"
echo "    docker compose --profile crawl-rust run --rm pipeline-rust  # another crawl"
echo "    docker compose --profile rust down -v                       # stop + clean volumes"
echo ""
echo "  To switch back to the Python stack:"
echo "    docker compose --profile rust down"
echo "    ./scripts/run-local.sh"
echo ""
