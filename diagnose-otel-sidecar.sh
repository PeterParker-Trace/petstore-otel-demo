#!/usr/bin/env bash
# diagnose-otel-sidecar.sh - Find out why OTEL Collector sidecars are crashing.
#
# Walks through:
#   1. Which tasks have failed otel-collector containers
#   2. Exit codes and stop reasons
#   3. CloudWatch logs from the failed collector containers
#   4. Common failure patterns and likely fixes
#
# Usage: ./diagnose-otel-sidecar.sh

set -uo pipefail

REGION="eu-north-1"
CLUSTER="petstore-otel-demo-cluster"
LOG_GROUP="/ecs/petstore-otel-demo"

# Colors
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  YELLOW=$'\033[0;33m'
  GREEN=$'\033[0;32m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED="" YELLOW="" GREEN="" CYAN="" BOLD="" RESET=""
fi

banner() {
  printf "\n%s===================================================================%s\n" "$CYAN" "$RESET"
  printf "%s%s%s\n" "$CYAN$BOLD" "$1" "$RESET"
  printf "%s===================================================================%s\n" "$CYAN" "$RESET"
}

# -----------------------------------------------------------------------------
banner "STEP 1: List ALL tasks (running + stopped) - find failed otel-collectors"
# -----------------------------------------------------------------------------

# Get all task ARNs (last 100 stopped + all running)
RUNNING_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING \
  --region "$REGION" --query 'taskArns' --output text 2>/dev/null)
STOPPED_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status STOPPED \
  --region "$REGION" --max-items 50 --query 'taskArns' --output text 2>/dev/null)

ALL_ARNS="$RUNNING_ARNS $STOPPED_ARNS"
ARN_COUNT=$(echo "$ALL_ARNS" | wc -w | tr -d ' ')
echo "Found $ARN_COUNT total task(s) to inspect."

if [ "$ARN_COUNT" = "0" ]; then
  echo "${RED}No tasks at all - cluster might be empty.${RESET}"
  exit 1
fi

# -----------------------------------------------------------------------------
banner "STEP 2: Find tasks with failed otel-collector containers"
# -----------------------------------------------------------------------------

# Describe each batch of tasks (max 100 per call)
echo "$ALL_ARNS" | tr ' ' '\n' | xargs -n 100 -I{} echo {} > /tmp/task-batches.txt 2>/dev/null

aws ecs describe-tasks --cluster "$CLUSTER" --tasks $ALL_ARNS \
  --region "$REGION" --output json > /tmp/all-tasks.json 2>/dev/null

# Use Python to extract relevant data
python3 <<'PYEOF'
import json, os, sys

with open('/tmp/all-tasks.json') as f:
    data = json.load(f)

failed_collectors = []
running_collectors = []

for task in data.get('tasks', []):
    task_arn = task['taskArn']
    task_id = task_arn.split('/')[-1]
    family = task.get('taskDefinitionArn', '').split('/')[-1].split(':')[0]
    last_status = task.get('lastStatus', 'UNKNOWN')

    for c in task.get('containers', []):
        if c.get('name') != 'otel-collector':
            continue
        cstatus = c.get('lastStatus', 'UNKNOWN')
        exit_code = c.get('exitCode')
        reason = c.get('reason', '')

        info = {
            'task_id': task_id,
            'family': family,
            'task_status': last_status,
            'container_status': cstatus,
            'exit_code': exit_code,
            'reason': reason,
            'started_at': c.get('lastStatus'),
            'stopped_reason': task.get('stoppedReason', ''),
        }

        if exit_code is not None and exit_code != 0:
            failed_collectors.append(info)
        elif cstatus == 'RUNNING':
            running_collectors.append(info)

print(f"Running otel-collector containers: {len(running_collectors)}")
for r in running_collectors:
    print(f"  OK   {r['family']} (task {r['task_id'][:12]})")

print()
print(f"Failed otel-collector containers: {len(failed_collectors)}")
for f in failed_collectors:
    print(f"  FAIL {f['family']} (task {f['task_id'][:12]}) - exit {f['exit_code']}, reason: {f['reason']}")
    if f['stopped_reason']:
        print(f"         task stop reason: {f['stopped_reason']}")

# Save task IDs for next step
with open('/tmp/failed-collector-tasks.txt', 'w') as out:
    for f in failed_collectors[:10]:  # last 10 failures
        out.write(f"{f['family']}|{f['task_id']}\n")
PYEOF

# -----------------------------------------------------------------------------
banner "STEP 3: Pull CloudWatch logs from failed otel-collector containers"
# -----------------------------------------------------------------------------

if [ ! -s /tmp/failed-collector-tasks.txt ]; then
  echo "${GREEN}No failed otel-collector containers found.${RESET}"
  echo "If you saw exit code 1 earlier, the task may have already been recycled."
  echo "Check the currently-running container logs instead:"
  echo ""
  echo "  aws logs tail $LOG_GROUP --since 10m --region $REGION --log-stream-name-prefix otel-collector"
else
  echo "Will fetch logs from up to 10 most recent failures."
  echo ""

  while IFS='|' read -r family task_id; do
    echo "${YELLOW}--- Logs from $family / task $task_id ---${RESET}"

    # The CloudWatch log stream name pattern from our task definitions:
    #   <stream-prefix>/<container-name>/<task-id>
    # For otel-collector container: otel-collector/otel-collector/<task-id>
    STREAM="otel-collector/otel-collector/$task_id"

    aws logs get-log-events \
      --log-group-name "$LOG_GROUP" \
      --log-stream-name "$STREAM" \
      --region "$REGION" \
      --start-from-head \
      --limit 50 \
      --query 'events[].message' \
      --output text 2>&1 | head -30

    echo ""
  done < /tmp/failed-collector-tasks.txt
fi

# -----------------------------------------------------------------------------
banner "STEP 4: Check current running otel-collector logs"
# -----------------------------------------------------------------------------

echo "Recent log lines from currently-running otel-collector sidecars (last 5 min):"
echo ""

aws logs tail "$LOG_GROUP" --since 5m --region "$REGION" \
  --log-stream-name-prefix "otel-collector" 2>/dev/null | tail -40

# -----------------------------------------------------------------------------
banner "STEP 5: Common Patterns and Likely Causes"
# -----------------------------------------------------------------------------

cat <<'EOF'

OTEL Collector exit code 1 - common causes ranked by frequency:

  1. INVALID CONFIG YAML
     Symptom: log line "Error: invalid configuration: ..."
     Fix:     Check the OTEL_CONFIG_YAML env var in task definition - escaping issues common

  2. CORALOGIX_PRIVATE_KEY env var empty/missing
     Symptom: "private_key is required" or "401 unauthorized"
     Fix:     Verify Secrets Manager has the value:
              aws secretsmanager get-secret-value \
                --secret-id petstore-otel-demo/coralogix_private_key \
                --region eu-north-1 --query SecretString --output text | head -c 10

  3. WRONG CORALOGIX REGION
     Symptom: "no such host" or "i/o timeout" on coralogix.com
     Fix:     Confirm domain matches your account region (eu2.coralogix.com)

  4. OOM (memory limit)
     Symptom: stopped reason "OutOfMemoryError" or exit 137
     Fix:     Increase memory in task definition

  5. CONFIG FILE WRITE FAILED
     Symptom: "/tmp/otel-config.yaml: Permission denied" or similar
     Fix:     Path/permission issue, switch to /var/tmp or rework command

  6. PERMANENT EXPORTER FAILURES
     Symptom: many "send_failed" metrics, then collector gives up
     Fix:     Network egress blocked, security group, NACLs

Run this script again after applying any fix - it'll show fresh data.

EOF
