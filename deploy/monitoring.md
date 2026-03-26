# Monitoring & Alerting Setup Guide

Comprehensive monitoring for the UpNews platform covering API uptime, crawl health, and infrastructure status.

## Services Used

### 1. Healthchecks.io (Free Tier)

Track pipeline crawl health and alert on failures.

**Setup:**

1. Create free account at https://healthchecks.io
2. Create two checks:
   - **Crawl Success:** Send a ping on successful pipeline run
   - **Crawl Failure:** Get alerted if pipeline fails
3. Copy ping URLs to GitHub Secrets:
   - `HEALTHCHECKS_CRAWL_URL` — success ping
   - `HEALTHCHECKS_CRAWL_URL_FAIL` — failure alert

**Usage in GitHub Actions:**

The scheduled crawl workflow (`.github/workflows/scheduled-crawl.yml`) automatically:
- POSTs to success URL on pipeline completion
- POSTs to failure URL with logs on error

**Alerting:**

Configure Healthchecks.io to notify via:
- Email
- Slack (webhook)
- PagerDuty
- SMS

### 2. UptimeRobot (Free Tier)

Monitor API endpoint availability.

**Setup:**

1. Create free account at https://uptimerobot.com
2. Add monitor:
   - URL: `https://api.upnews.com/health`
   - Interval: Every 5 minutes
   - Alert contacts: Email + Slack webhook
3. Configure alerting rules:
   - Alert after 2 consecutive failures
   - Recovery email on success

**What it checks:**

```bash
curl https://api.upnews.com/health
```

Expected response (200 OK):
```json
{
  "status": "healthy",
  "uptime": 99.9,
  "last_crawl": "2024-03-25T12:00:00Z"
}
```

### 3. GitHub Actions Health Check Workflow

Optional: Add `.github/workflows/health-check.yml` to run automatic checks.

**Setup:**

Add this to `.github/workflows/health-check.yml`:

```yaml
name: Health Check - API

on:
  schedule:
    - cron: '*/10 * * * *'  # Every 10 minutes
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Check API health
        run: |
          curl -f https://api.upnews.com/health || exit 1

      - name: Check database connectivity
        env:
          DATABASE_URL: ${{ secrets.TURSO_URL }}
          TURSO_TOKEN: ${{ secrets.TURSO_TOKEN }}
        run: |
          echo "Checking database..."
          # Add health query here

      - name: Report failure
        if: failure()
        env:
          SLACK_WEBHOOK: ${{ secrets.SLACK_WEBHOOK_URL }}
        run: |
          curl -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d '{"text": "UpNews API health check failed"}'
```

## Environment Variables & Secrets

Set these in GitHub Secrets (Settings → Secrets → Actions):

```bash
# Healthchecks.io
HEALTHCHECKS_CRAWL_URL=https://hc-ping.com/your-uuid-here

# UptimeRobot
UPTIMEROBOT_API_KEY=your-api-key

# Slack alerting
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL

# Email alerting
ALERT_EMAIL=ops@upnews.com
```

## Monitoring Checklist

Track these metrics:

### API Health

- [ ] Response time < 500ms
- [ ] Error rate < 1%
- [ ] Uptime > 99.5%
- [ ] Health endpoint responding

### Pipeline Health

- [ ] Crawl completes every 4 hours
- [ ] New articles being indexed
- [ ] ML model inference time < 5s per article
- [ ] Database writes succeeding

### Infrastructure

- [ ] Memory usage < 256MB (shared CPU)
- [ ] CPU usage < 30% average
- [ ] Disk space available (if using local SQLite)
- [ ] All services reachable by hostname

### Database

- [ ] Query response time < 100ms
- [ ] Connection pool healthy
- [ ] Backup completed (if using Turso)
- [ ] Row count growing with each crawl

## Alerting Rules

### Critical (Alert Immediately)

- API endpoint returns 5xx error (alert after 2 failures)
- Database connection fails
- Pipeline fails 2 consecutive runs
- Uptime drops below 95%

### Warning (Alert After Pattern)

- Response time exceeds 1s (average over 5 min)
- Error rate exceeds 5% (over 10 min window)
- Crawl takes > 30 minutes (abnormally slow)
- New articles not indexed for 8 hours

### Info (Log Only)

- Successful crawl completion
- Daily statistics (article count, topics processed)
- Performance improvements

## Dashboard Setup

Create a simple monitoring dashboard:

### Option 1: GitHub Insights (Built-in)

Track in GitHub Actions:
- Workflow runs over time
- Success rate per workflow
- Artifact storage

### Option 2: Healthchecks.io Dashboard

Visual status page showing:
- Last check time
- Uptime percentage
- Check history (24h/7d)

### Option 3: Custom Dashboard (DIY)

Build with:
- Grafana (free tier)
- Prometheus + node_exporter
- Custom Python script logging metrics

## On-Call & Incident Response

### Alert Escalation

1. **First Alert:** Slack notification
2. **No Response in 15 min:** Email notification
3. **No Response in 1h:** SMS (if configured)

### Incident Checklist

When alerted:

1. Check GitHub Actions for failures
2. SSH into app (if self-hosted) or check logs in Fly.io/Render
3. Review database connectivity
4. Check external API status (news feeds)
5. Rollback recent deployment if needed
6. Post incident update to #status channel

### Recovery Procedures

**If API is down:**

```bash
# Check logs
flyctl logs

# Restart service
flyctl apps restart

# Rollback to previous version
flyctl releases list
flyctl releases rollback <VERSION>
```

**If pipeline fails:**

```bash
# Trigger manual re-run
gh workflow run scheduled-crawl.yml

# Check pipeline logs
gh run list --workflow=scheduled-crawl.yml
```

**If database is locked/corrupted:**

```bash
# For Turso (no action needed, auto-replicated)
turso db shell upnews-db

# For local SQLite, restore from backup
sqlite3 upnews.db ".restore backup.db"
```

## Monitoring Cost Breakdown

| Service | Cost | Limit | Notes |
|---------|------|-------|-------|
| Healthchecks.io | $0 | 20 checks free | Paid $60/yr for unlimited |
| UptimeRobot | $0 | 50 monitors free | Basic SMS alerts |
| GitHub Actions | $0 | 2,000 min/mo free | Included in free plan |
| Slack | $0 | Unlimited messages | Free tier |
| **Total** | **$0/mo** | — | Free with small overhead |

## References

- [Healthchecks.io Docs](https://healthchecks.io/docs/)
- [UptimeRobot API](https://uptimerobot.com/api)
- [GitHub Actions Monitoring](https://docs.github.com/en/actions/monitoring-and-troubleshooting-workflows)
- [Fly.io Monitoring](https://fly.io/docs/reference/log-streaming/)
