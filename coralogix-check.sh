#!/usr/bin/env bash
# coralogix-check.sh — verify Phase 3 Coralogix exporter is healthy.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

separator() {
  echo ""
  echo "=========================================="
  echo "$1"
  echo "=========================================="
}

separator "1. Collector container status"
docker compose ps otel-collector --format "table {{.Name}}\t{{.Status}}"

separator "2. CORALOGIX_PRIVATE_KEY env var visible inside Collector?"
docker compose exec otel-collector sh -c '
  if [ -n "$CORALOGIX_PRIVATE_KEY" ]; then
    echo "Set: yes (length=${#CORALOGIX_PRIVATE_KEY})"
  else
    echo "Set: NO -- check your .env file"
  fi
' || echo "(Could not exec into collector)"

separator "3. Collector internal logs (last 30 non-payload lines)"
docker compose logs --tail=30 otel-collector 2>&1 | grep -v "Span\|Metric\|LogRecord\|HistogramDataPoint\|Bucket\|ExplicitBound\|Resource attributes\|Data point" | tail -30

separator "4. Searching for Coralogix exporter errors"
ERRORS=$(docker compose logs otel-collector 2>&1 | grep -iE "coralogix.*(error|fail|reject|denied|unauthor)" | tail -10)
if [ -z "$ERRORS" ]; then
  echo "No Coralogix exporter errors found. Good sign."
else
  echo "Found errors:"
  echo "$ERRORS"
fi

separator "5. Trigger a fresh order"
RESULT=$(curl -s -X POST http://localhost:3000/api/orders \
  -H "Content-Type: application/json" \
  -d '{"pet_id": 4, "quantity": 1, "customer_email": "phase3@example.com"}')
echo "Order: $RESULT"

separator "Done. Open Coralogix UI and look for application='petstore'."
echo "Allow ~30-60 seconds for first data to appear."
