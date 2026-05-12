#!/usr/bin/env bash
# ecs-health-check.sh - Layered health check for the petstore-otel-demo ECS deployment
#
# Walks through 10 layers from AWS account down to live HTTP connectivity, flagging
# any problems found. At the end prints a summary of issues plus suggested next steps.
#
# Run anytime: ./ecs-health-check.sh
# Verbose mode: ./ecs-health-check.sh -v   (shows full output instead of summaries)

set -uo pipefail
# Note: NOT using -e. We want to keep checking even if individual queries fail,
# so we can report a comprehensive picture rather than stopping at the first issue.

VERBOSE=0
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--verbose" ]; then
  VERBOSE=1
fi

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
REGION="eu-north-1"
CLUSTER="petstore-otel-demo-cluster"
SERVICES=(postgres catalog-service payments-service orders-service api-gateway frontend)
PROJECT_TAG="petstore-otel-demo"
LOG_GROUP="/ecs/petstore-otel-demo"

# Issue tracking arrays
ERRORS=()
WARNINGS=()

# -----------------------------------------------------------------------------
# Pretty output helpers
# -----------------------------------------------------------------------------
# Colors only if terminal supports them
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

ok()   { printf "  ${GREEN}OK${RESET}     %s\n" "$1"; }
warn() { printf "  ${YELLOW}WARN${RESET}   %s\n" "$1"; WARNINGS+=("$1"); }
err()  { printf "  ${RED}ERROR${RESET}  %s\n" "$1"; ERRORS+=("$1"); }
info() { printf "         %s\n" "$1"; }

# Run command, capture stdout into variable, return exit code
# Usage: capture VAR_NAME aws ec2 ...
capture() {
  local var=$1; shift
  local out
  out=$("$@" 2>&1)
  local rc=$?
  printf -v "$var" '%s' "$out"
  return $rc
}

# -----------------------------------------------------------------------------
banner "LAYER 1: AWS Account & Permissions"
# -----------------------------------------------------------------------------

capture WHO aws sts get-caller-identity --output json
if [ $? -ne 0 ]; then
  err "AWS CLI not authenticated or not configured"
  info "Fix: configure with 'aws configure' or set env vars"
  echo "$WHO"
  echo ""
  printf "${RED}Cannot proceed without AWS access. Stopping.${RESET}\n"
  exit 1
fi

ACCOUNT=$(echo "$WHO" | grep -o '"Account": *"[^"]*"' | cut -d'"' -f4)
ARN=$(echo "$WHO" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)
ok "Authenticated as $ARN"
info "Account: $ACCOUNT, Region: $REGION"

# -----------------------------------------------------------------------------
banner "LAYER 2: ECS Cluster"
# -----------------------------------------------------------------------------

capture CLUSTER_JSON aws ecs describe-clusters --clusters "$CLUSTER" --region "$REGION" --output json
if echo "$CLUSTER_JSON" | grep -q '"failures"' && echo "$CLUSTER_JSON" | grep -q "MISSING"; then
  err "Cluster '$CLUSTER' does not exist"
  info "Fix: run 'terraform apply' in terraform/ephemeral"
  printf "\n${RED}Cluster missing. Cannot continue checks.${RESET}\n"
  exit 1
fi

STATUS=$(echo "$CLUSTER_JSON" | grep -o '"status": *"[^"]*"' | head -1 | cut -d'"' -f4)
REGISTERED=$(echo "$CLUSTER_JSON" | grep -o '"registeredContainerInstancesCount": *[0-9]*' | head -1 | grep -o '[0-9]*')
RUNNING=$(echo "$CLUSTER_JSON" | grep -o '"runningTasksCount": *[0-9]*' | head -1 | grep -o '[0-9]*')
PENDING=$(echo "$CLUSTER_JSON" | grep -o '"pendingTasksCount": *[0-9]*' | head -1 | grep -o '[0-9]*')
ACTIVE_SVC=$(echo "$CLUSTER_JSON" | grep -o '"activeServicesCount": *[0-9]*' | head -1 | grep -o '[0-9]*')

if [ "$STATUS" = "ACTIVE" ]; then
  ok "Cluster status: ACTIVE"
else
  err "Cluster status: $STATUS"
fi

info "Container instances: $REGISTERED"
info "Running tasks: $RUNNING"
info "Pending tasks: $PENDING"
info "Active services: $ACTIVE_SVC"

if [ "$REGISTERED" = "0" ]; then
  err "No container instances registered - ASG may not have launched, or ECS agent failed to register"
  info "Check: aws autoscaling describe-auto-scaling-groups --region $REGION"
fi

EXPECTED_TASKS=${#SERVICES[@]}
if [ "$RUNNING" != "$EXPECTED_TASKS" ]; then
  warn "Expected $EXPECTED_TASKS running tasks, got $RUNNING"
fi

# -----------------------------------------------------------------------------
banner "LAYER 3: EC2 Instances"
# -----------------------------------------------------------------------------

capture EC2_JSON aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,PublicIpAddress]' \
  --output text

if [ -z "$EC2_JSON" ]; then
  err "No running EC2 instances tagged Project=$PROJECT_TAG"
else
  COUNT=$(echo "$EC2_JSON" | wc -l | tr -d ' ')
  ok "$COUNT running EC2 instance(s):"
  echo "$EC2_JSON" | while read -r line; do
    info "  $line"
  done
fi

# -----------------------------------------------------------------------------
banner "LAYER 4: Container Instance Resources"
# -----------------------------------------------------------------------------

capture CI_ARNS aws ecs list-container-instances --cluster "$CLUSTER" --region "$REGION" \
  --query 'containerInstanceArns' --output text

if [ -z "$CI_ARNS" ] || [ "$CI_ARNS" = "None" ]; then
  err "No container instances in cluster"
else
  capture CI_DETAIL aws ecs describe-container-instances \
    --cluster "$CLUSTER" --container-instances $CI_ARNS --region "$REGION" --output json

  # Extract per-CI resource info using python (more reliable than grep)
  echo "$CI_DETAIL" | python3 <<'PYEOF' 2>/dev/null || warn "Could not parse container instance details"
import json, sys, os
data = json.load(sys.stdin)
for ci in data.get('containerInstances', []):
    agent_connected = ci.get('agentConnected', False)
    status = ci.get('status', 'UNKNOWN')
    print(f"  Container instance: {ci.get('ec2InstanceId', '?')}")
    print(f"    Status: {status}, Agent connected: {agent_connected}")
    if not agent_connected:
        print(f"    ERROR: ECS agent disconnected - investigate with SSM session")
    if status != 'ACTIVE':
        print(f"    ERROR: Container instance not ACTIVE")

    registered = {r['name']: r.get('integerValue', r.get('doubleValue', 0))
                  for r in ci.get('registeredResources', [])
                  if r['name'] in ('CPU', 'MEMORY')}
    remaining = {r['name']: r.get('integerValue', r.get('doubleValue', 0))
                 for r in ci.get('remainingResources', [])
                 if r['name'] in ('CPU', 'MEMORY')}

    cpu_used = registered.get('CPU', 0) - remaining.get('CPU', 0)
    cpu_pct = (cpu_used / registered['CPU'] * 100) if registered.get('CPU') else 0
    mem_used = registered.get('MEMORY', 0) - remaining.get('MEMORY', 0)
    mem_pct = (mem_used / registered['MEMORY'] * 100) if registered.get('MEMORY') else 0

    print(f"    CPU: {cpu_used}/{registered.get('CPU', 0)} ({cpu_pct:.0f}%), remaining {remaining.get('CPU', 0)}")
    print(f"    Memory: {mem_used}/{registered.get('MEMORY', 0)} MB ({mem_pct:.0f}%), remaining {remaining.get('MEMORY', 0)} MB")

    if cpu_pct > 90:
        print(f"    WARN: CPU >90% reserved - may not fit additional tasks")
    if mem_pct > 90:
        print(f"    WARN: Memory >90% reserved - may not fit additional tasks")

    running_tasks = ci.get('runningTasksCount', 0)
    pending_tasks = ci.get('pendingTasksCount', 0)
    print(f"    Tasks: {running_tasks} running, {pending_tasks} pending")
PYEOF
fi

# -----------------------------------------------------------------------------
banner "LAYER 5: ECS Services"
# -----------------------------------------------------------------------------

SVC_LIST="${SERVICES[*]}"
capture SVC_JSON aws ecs describe-services --cluster "$CLUSTER" \
  --services $SVC_LIST --region "$REGION" --output json

# Per-service table
echo "$SVC_JSON" | python3 <<PYEOF 2>/dev/null
import json, sys
data = json.load(sys.stdin)
print()
print(f"  {'Service':<20} {'Running':<8} {'Desired':<8} {'State':<14} {'Recent task'}")
print(f"  {'-'*20} {'-'*8} {'-'*8} {'-'*14} {'-'*40}")
for s in data.get('services', []):
    name = s['serviceName']
    running = s.get('runningCount', 0)
    desired = s.get('desiredCount', 0)
    deps = s.get('deployments', [])
    state = deps[0].get('rolloutState', 'UNKNOWN') if deps else 'NONE'
    # Latest event message
    events = s.get('events', [])
    last_event = events[0]['message'][:55] if events else ''
    print(f"  {name:<20} {running:<8} {desired:<8} {state:<14} {last_event}")
PYEOF

echo ""

# Identify problem services
echo "$SVC_JSON" | python3 <<PYEOF 2>/dev/null
import json, sys
data = json.load(sys.stdin)
for s in data.get('services', []):
    name = s['serviceName']
    running = s.get('runningCount', 0)
    desired = s.get('desiredCount', 0)
    deps = s.get('deployments', [])
    state = deps[0].get('rolloutState', 'UNKNOWN') if deps else 'NONE'
    if running < desired:
        print(f"PROBLEM:{name}:{state}:{running}/{desired}")
        events = s.get('events', [])[:3]
        for e in events:
            print(f"  EVENT:{e.get('createdAt', '')}: {e['message']}")
PYEOF
PROBLEM_SERVICES=$(echo "$SVC_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
problems = []
for s in data.get('services', []):
    if s.get('runningCount', 0) < s.get('desiredCount', 0):
        problems.append(s['serviceName'])
print(' '.join(problems))
" 2>/dev/null)

if [ -n "$PROBLEM_SERVICES" ]; then
  for svc in $PROBLEM_SERVICES; do
    err "Service '$svc' is not at desired count"
  done
else
  ok "All services at desired count"
fi

# -----------------------------------------------------------------------------
banner "LAYER 6: Stopped Tasks (last 10)"
# -----------------------------------------------------------------------------

capture STOPPED_ARNS aws ecs list-tasks --cluster "$CLUSTER" --desired-status STOPPED \
  --region "$REGION" --max-items 10 --query 'taskArns' --output text

if [ -z "$STOPPED_ARNS" ] || [ "$STOPPED_ARNS" = "None" ]; then
  ok "No recently stopped tasks"
else
  STOPPED_COUNT=$(echo "$STOPPED_ARNS" | wc -w | tr -d ' ')
  info "$STOPPED_COUNT recently stopped task(s) found"

  capture TASKS_JSON aws ecs describe-tasks --cluster "$CLUSTER" \
    --tasks $STOPPED_ARNS --region "$REGION" --output json

  echo "$TASKS_JSON" | python3 <<'PYEOF' 2>/dev/null
import json, sys
data = json.load(sys.stdin)
for t in data.get('tasks', []):
    family = t.get('taskDefinitionArn', '').split('/')[-1].split(':')[0]
    last_status = t.get('lastStatus', '?')
    stopped_reason = t.get('stoppedReason', '(no reason)')
    print(f"\n  {family} ({last_status}): {stopped_reason}")
    for c in t.get('containers', []):
        cname = c.get('name', '?')
        exit_code = c.get('exitCode', 'N/A')
        reason = c.get('reason', '')
        if reason:
            print(f"    Container '{cname}': exit code {exit_code}, reason: {reason}")
        elif exit_code != 'N/A':
            print(f"    Container '{cname}': exit code {exit_code}")
PYEOF
fi

# -----------------------------------------------------------------------------
banner "LAYER 7: Running Tasks"
# -----------------------------------------------------------------------------

capture RUNNING_ARNS aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING \
  --region "$REGION" --query 'taskArns' --output text

if [ -z "$RUNNING_ARNS" ] || [ "$RUNNING_ARNS" = "None" ]; then
  err "No running tasks at all"
else
  RUN_COUNT=$(echo "$RUNNING_ARNS" | wc -w | tr -d ' ')
  ok "$RUN_COUNT running task(s)"

  capture RUN_JSON aws ecs describe-tasks --cluster "$CLUSTER" \
    --tasks $RUNNING_ARNS --region "$REGION" --output json

  echo "$RUN_JSON" | python3 <<'PYEOF' 2>/dev/null
import json, sys
data = json.load(sys.stdin)
print()
for t in data.get('tasks', []):
    family = t.get('taskDefinitionArn', '').split('/')[-1]
    health = t.get('healthStatus', 'UNKNOWN')
    cpu = t.get('cpu', '?')
    mem = t.get('memory', '?')
    print(f"  {family} - health: {health}, cpu: {cpu}, mem: {mem}MB")
    for c in t.get('containers', []):
        cname = c.get('name', '?')
        cstatus = c.get('lastStatus', '?')
        chealth = c.get('healthStatus', 'UNKNOWN')
        print(f"    {cname}: {cstatus} ({chealth})")
PYEOF
fi

# -----------------------------------------------------------------------------
banner "LAYER 8: Recent CloudWatch Logs (Problem Services)"
# -----------------------------------------------------------------------------

if [ -n "$PROBLEM_SERVICES" ]; then
  for svc in $PROBLEM_SERVICES; do
    info "--- Logs for $svc (last 5 min, 20 lines) ---"
    aws logs tail "$LOG_GROUP" --since 5m --region "$REGION" \
      --log-stream-name-prefix "$svc" 2>/dev/null | tail -20 \
      || warn "Could not fetch logs for $svc"
    echo ""
  done
else
  ok "No problem services - skipping log inspection"
  info "(use -v flag to fetch logs from all services anyway)"
fi

# -----------------------------------------------------------------------------
banner "LAYER 9: ALB Target Health"
# -----------------------------------------------------------------------------

capture TG_ARN aws elbv2 describe-target-groups --region "$REGION" \
  --names petstore-otel-demo-frontend --query 'TargetGroups[0].TargetGroupArn' --output text

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  err "Target group 'petstore-otel-demo-frontend' not found"
else
  capture TH_JSON aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --region "$REGION" --output json

  echo "$TH_JSON" | python3 <<'PYEOF' 2>/dev/null
import json, sys
data = json.load(sys.stdin)
targets = data.get('TargetHealthDescriptions', [])
if not targets:
    print("  ERROR: No targets registered with target group")
else:
    print(f"  {len(targets)} target(s) registered:")
    healthy = 0
    for t in targets:
        tid = t['Target']['Id']
        port = t['Target']['Port']
        state = t['TargetHealth']['State']
        reason = t['TargetHealth'].get('Reason', '')
        desc = t['TargetHealth'].get('Description', '')
        marker = 'OK' if state == 'healthy' else 'WARN'
        print(f"    [{marker}] {tid}:{port} - {state} {reason} {desc}")
        if state == 'healthy':
            healthy += 1
    if healthy == 0:
        print("  ERROR: No healthy targets - ALB will return 503")
PYEOF
fi

# -----------------------------------------------------------------------------
banner "LAYER 10: ALB HTTP Smoke Test"
# -----------------------------------------------------------------------------

# Try to get ALB DNS from Terraform output, fall back to AWS if it fails
ALB_DNS=""
if [ -d "/Users/admin/Documents/roy-app/petstore-otel-demo/terraform/ephemeral" ]; then
  ALB_DNS=$(cd /Users/admin/Documents/roy-app/petstore-otel-demo/terraform/ephemeral && terraform output -raw alb_dns_name 2>/dev/null)
fi
if [ -z "$ALB_DNS" ]; then
  ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --names petstore-otel-demo-alb --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
fi

if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "None" ]; then
  err "Could not determine ALB DNS name"
else
  ok "ALB DNS: $ALB_DNS"
  info "Testing http://$ALB_DNS/health (5s timeout)..."

  STATUS=$(curl -sS -m 5 -o /tmp/alb-resp.txt -w "%{http_code}" "http://$ALB_DNS/health" 2>&1)
  CURL_RC=$?

  if [ $CURL_RC -ne 0 ]; then
    err "curl failed: $STATUS"
  elif [ "$STATUS" = "200" ]; then
    BODY=$(cat /tmp/alb-resp.txt)
    ok "HTTP 200 - body: $BODY"
  elif [ "$STATUS" = "503" ]; then
    err "HTTP 503 - no healthy targets, see Layer 9"
  elif [ "$STATUS" = "504" ]; then
    err "HTTP 504 - gateway timeout, backend not responding"
  else
    warn "HTTP $STATUS - unexpected status"
    cat /tmp/alb-resp.txt 2>/dev/null | head -5
  fi
fi

# -----------------------------------------------------------------------------
banner "SUMMARY"
# -----------------------------------------------------------------------------

if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
  printf "\n  ${GREEN}${BOLD}All checks passed.${RESET}\n\n"
  info "Stack is healthy. Visit: http://$ALB_DNS"
else
  if [ ${#ERRORS[@]} -gt 0 ]; then
    printf "\n  %s%d error(s):%s\n" "$RED$BOLD" "${#ERRORS[@]}" "$RESET"
    for e in "${ERRORS[@]}"; do
      printf "    ${RED}*${RESET} %s\n" "$e"
    done
  fi
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    printf "\n  %s%d warning(s):%s\n" "$YELLOW$BOLD" "${#WARNINGS[@]}" "$RESET"
    for w in "${WARNINGS[@]}"; do
      printf "    ${YELLOW}*${RESET} %s\n" "$w"
    done
  fi

  cat <<-EOF

  Suggested next steps based on findings:
    - For "service not at desired count": see Layer 5 events and Layer 6/8 logs
    - For "no healthy targets": frontend task may be unhealthy, see Layer 7
    - For "insufficient CPU": reduce CPU per task or scale ASG
    - For "RESOURCE:ENI": ensure trunking is enabled (account setting)
    - For "agent disconnected": SSM into the EC2 to check /var/log/ecs/

EOF
fi

# Total counts for scripting
echo ""
echo "Issue counts (machine-readable):"
echo "  errors=${#ERRORS[@]}"
echo "  warnings=${#WARNINGS[@]}"
