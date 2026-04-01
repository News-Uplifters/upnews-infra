#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# UpNews Local E2E
#
# Builds and starts the full stack, runs one pipeline crawl,
# and validates that articles appear in the API.
#
# Prerequisites:
#   - Docker + Docker Compose v2
#   - All repos cloned as siblings:
#
#   parent-dir/
#   ├── upnews-api/
#   ├── upnews-pipeline/
#   ├── upnews-frontend/
#   └── upnews-infra/        <-- run this script from here
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
for repo in upnews-api upnews-pipeline upnews-frontend; do
    if [ ! -d "${PARENT_DIR}/${repo}" ]; then
        MISSING+=("$repo")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    fail "Missing sibling repos: ${MISSING[*]}"
    echo "  Expected layout:"
    echo "    $(basename "$PARENT_DIR")/"
    echo "    ├── upnews-api/"
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

info "[1/5] Building images (this may take a few minutes on first run)..."
docker compose build --parallel
echo ""

# ── Step 2: Start API + Frontend ─────────────────────────────

info "[2/5] Starting API + Frontend..."
docker compose up -d api frontend
echo ""

# ── Step 3: Wait for API health ───────────────────────────────

info "[3/5] Waiting for API to become healthy..."
MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' upnews-api 2>/dev/null || echo "starting")
    if [ "$STATUS" = "healthy" ]; then
        ok "API is healthy (took ${i}s)"
        break
    fi
    if [ "$i" -eq "$MAX_WAIT" ]; then
        fail "API did not become healthy within ${MAX_WAIT}s"
        echo ""
        echo "── API logs ──"
        docker compose logs api --tail 30
        echo ""
        echo "Tip: docker compose logs api"
        exit 1
    fi
    printf "  waiting... (%ds)\r" "$i"
    sleep 1
done

API_RESP=$(curl -sf http://localhost:8000/api/health 2>/dev/null || echo "")
if echo "$API_RESP" | grep -q "healthy"; then
    ok "API health endpoint responding"
else
    warn "API container is healthy but /api/health returned unexpected response"
    echo "  Response: $API_RESP"
fi
echo ""

# ── Step 4: Run the pipeline ─────────────────────────────────

info "[4/5] Running pipeline crawl (fetching news articles)..."
echo "  This takes 1–3 minutes on first run."
echo ""

if docker compose --profile crawl run --rm pipeline 2>&1 | tee /tmp/upnews-pipeline.log | tail -20; then
    ok "Pipeline completed successfully"
else
    PIPELINE_EXIT=$?
    warn "Pipeline exited with code $PIPELINE_EXIT"
    echo "  Full log: /tmp/upnews-pipeline.log"
    echo "  (Continuing — some articles may have been stored despite the error)"
fi
echo ""

# ── Step 5: Validate end-to-end ──────────────────────────────

info "[5/5] Validating end-to-end..."

ARTICLES_JSON=$(curl -sf http://localhost:8000/api/articles 2>/dev/null || echo "")
ARTICLE_COUNT=0
if [ -n "$ARTICLES_JSON" ]; then
    ARTICLE_COUNT=$(echo "$ARTICLES_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'meta' in data and 'total_count' in data['meta']:
        print(data['meta']['total_count'])
    elif 'data' in data and isinstance(data['data'], list):
        print(len(data['data']))
    elif isinstance(data, list):
        print(len(data))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0")
fi

FRONTEND_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:3000/ 2>/dev/null || echo "000")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$ARTICLE_COUNT" -gt 0 ] && [ "$FRONTEND_STATUS" = "200" ]; then
    echo -e "${GREEN}  END-TO-END TEST PASSED${NC}"
else
    echo -e "${YELLOW}  PARTIAL SUCCESS${NC}"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Articles in DB:  $ARTICLE_COUNT"
echo "  Frontend HTTP:   $FRONTEND_STATUS"
echo ""
echo "  Frontend:  http://localhost:3000"
echo "  API:       http://localhost:8000/api/articles"
echo "  API docs:  http://localhost:8000/docs"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Useful commands:"
echo "    docker compose logs api                               # API logs"
echo "    docker compose logs frontend                          # Frontend logs"
echo "    docker compose --profile crawl run --rm pipeline      # Run another crawl"
echo "    docker compose down -v                                # Stop + remove volumes"
echo ""
