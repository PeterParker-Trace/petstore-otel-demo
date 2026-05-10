#!/usr/bin/env bash
# trace-flow-check.sh
# Targeted check: trigger ONE order, then locate that exact trace
# in the Collector logs and show which services participated in it.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

separator() {
  echo ""
  echo "=========================================="
  echo "$1"
  echo "=========================================="
}

separator "Step 1: capture log baseline"
# Mark current end of logs by recording line count, so we only look at NEW lines.
BASELINE=$(docker compose logs otel-collector 2>&1 | wc -l | tr -d ' ')
echo "Baseline log line count: $BASELINE"

separator "Step 2: trigger one order"
RESULT=$(curl -s -X POST http://localhost:3000/api/orders \
  -H "Content-Type: application/json" \
  -d '{"pet_id": 3, "quantity": 1, "customer_email": "tracecheck@example.com"}')
echo "Order result: $RESULT"

separator "Step 3: wait for telemetry to flush"
sleep 8
echo "Done waiting."

separator "Step 4: extract only NEW log lines since baseline"
# tail starting after the baseline gives us only new content
NEW_LOGS=$(docker compose logs otel-collector 2>&1 | tail -n +"$BASELINE")
NEW_LINE_COUNT=$(echo "$NEW_LOGS" | wc -l | tr -d ' ')
echo "New log lines collected: $NEW_LINE_COUNT"

separator "Step 5: list all trace IDs in the new logs (with counts)"
echo "$NEW_LOGS" | grep -oE "[0-9a-f]{32}" | sort | uniq -c | sort -rn | head -10
echo ""
echo "(Higher counts = traces with more spans/logs)"

separator "Step 6: pick the trace ID with the most mentions"
TOP_TID=$(echo "$NEW_LOGS" | grep -oE "[0-9a-f]{32}" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
TOP_COUNT=$(echo "$NEW_LOGS" | grep -oE "[0-9a-f]{32}" | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
echo "Top trace ID: $TOP_TID  ($TOP_COUNT mentions)"

separator "Step 7: which services participated in that top trace?"
# Find each block of output containing the trace ID and look back to find its service.name
echo "$NEW_LOGS" | awk -v tid="$TOP_TID" '
  /service\.name: Str\(/ { current_svc = $0 }
  $0 ~ tid { print current_svc }
' | sort -u

separator "Step 8: span/log/metric counts in the new logs"
echo "Spans:   $(echo "$NEW_LOGS" | grep -c "ResourceSpans" || true)"
echo "Logs:    $(echo "$NEW_LOGS" | grep -c "ResourceLog" || true)"
echo "Metrics: $(echo "$NEW_LOGS" | grep -c "ResourceMetrics" || true)"

separator "Done. Paste the entire output above."
