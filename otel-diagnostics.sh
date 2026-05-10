#!/usr/bin/env bash
# otel-diagnostics.sh
# Single script that gathers all OTEL pipeline diagnostics in one run.
# Output is paste-friendly so you can hand it back to your TAM mentor.
#
# Usage:
#   chmod +x otel-diagnostics.sh
#   ./otel-diagnostics.sh

set -u  # error on unset variables

# Move to the project directory regardless of where the script is run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

separator() {
  echo ""
  echo "=========================================="
  echo "$1"
  echo "=========================================="
}

separator "1. Running containers"
docker compose ps --format "table {{.Name}}\t{{.Status}}"

separator "2. Total Collector log lines captured"
TOTAL_LINES=$(docker compose logs otel-collector 2>&1 | wc -l | tr -d ' ')
echo "Lines: $TOTAL_LINES"

separator "3. Signal counts (batches received)"
SPANS=$(docker compose logs otel-collector 2>&1 | grep -c "ResourceSpans" || true)
LOGS=$(docker compose logs otel-collector 2>&1 | grep -c "ResourceLog" || true)
METRICS=$(docker compose logs otel-collector 2>&1 | grep -c "ResourceMetrics" || true)
printf "Spans batches:   %s\n" "$SPANS"
printf "Logs batches:    %s\n" "$LOGS"
printf "Metrics batches: %s\n" "$METRICS"

separator "4. Unique services emitting telemetry"
docker compose logs otel-collector 2>&1 \
  | grep -oE "service.name: Str\([^)]+\)" \
  | sort -u
echo ""
echo "(Expected 5: api-gateway, catalog-service, frontend, orders-service, payments-service)"

separator "5. Generate a fresh order to capture a real trace"
RESULT=$(curl -s -X POST http://localhost:3000/api/orders \
  -H "Content-Type: application/json" \
  -d '{"pet_id": 3, "quantity": 1, "customer_email": "diagscript@example.com"}')
echo "Order result: $RESULT"

echo ""
echo "Waiting 6 seconds for telemetry to flush through the Collector..."
sleep 6

separator "6. Most recent Trace IDs (deduplicated)"
RECENT_TRACES=$(docker compose logs --tail=2000 otel-collector 2>&1 \
  | grep -oE "[0-9a-f]{32}" \
  | sort -u \
  | tail -5)
echo "$RECENT_TRACES"

separator "7. Span count for each recent trace"
for TID in $RECENT_TRACES; do
  COUNT=$(docker compose logs --tail=5000 otel-collector 2>&1 | grep -c "$TID" || true)
  printf "  %s -> %s mentions\n" "$TID" "$COUNT"
done

separator "8. Sample spans from one trace (last one)"
LAST_TID=$(echo "$RECENT_TRACES" | tail -1)
if [[ -n "$LAST_TID" ]]; then
  echo "Examining trace: $LAST_TID"
  echo ""
  docker compose logs --tail=5000 otel-collector 2>&1 \
    | grep -B2 -A4 "$LAST_TID" \
    | grep -E "(service\.name|Trace ID|Name|Kind)" \
    | head -40
fi

separator "Done. Paste the entire output above to your TAM mentor."
