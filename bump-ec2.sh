#!/usr/bin/env bash
# bump-ec2.sh - Upgrade ECS host from m6g.large to m6g.xlarge
#
# Layered implementation with checkpoints between each step so any failure
# is contained and visible. Run from the project root or from anywhere -
# the script cd's to the right directory on its own.

set -euo pipefail

# Paths
PROJECT_ROOT="/Users/admin/Documents/roy-app/petstore-otel-demo"
TF_DIR="$PROJECT_ROOT/terraform/ephemeral"
REGION="eu-north-1"
CLUSTER="petstore-otel-demo-cluster"

# Pretty output helpers
banner() { printf "\n=========================================================\n%s\n=========================================================\n" "$1"; }
step()   { printf "\n--- %s ---\n" "$1"; }
ok()     { printf "  OK: %s\n" "$1"; }
fail()   { printf "  FAIL: %s\n" "$1"; exit 1; }

# -----------------------------------------------------------------------------
banner "STEP 1: Verify prerequisites"
# -----------------------------------------------------------------------------

step "Checking we can reach AWS"
aws sts get-caller-identity --query 'Account' --output text || fail "AWS CLI not authenticated"
ok "AWS authenticated"

step "Checking Terraform directory exists"
[ -d "$TF_DIR" ] || fail "Terraform directory not found: $TF_DIR"
cd "$TF_DIR"
ok "In $TF_DIR"

step "Checking terraform.tfvars exists"
[ -f terraform.tfvars ] || fail "terraform.tfvars not found - run from project that's already initialized"
ok "terraform.tfvars present"

# -----------------------------------------------------------------------------
banner "STEP 2: Update tfvars to m6g.xlarge"
# -----------------------------------------------------------------------------

step "Current instance_type setting"
grep "^instance_type" terraform.tfvars 2>/dev/null || echo "  (not set - will be appended)"

step "Setting instance_type = m6g.xlarge"
if grep -q "^instance_type" terraform.tfvars; then
  sed -i '' 's/^instance_type.*/instance_type = "m6g.xlarge"/' terraform.tfvars
  ok "Replaced existing instance_type"
else
  echo 'instance_type = "m6g.xlarge"' >> terraform.tfvars
  ok "Appended instance_type"
fi

step "Verify tfvars now"
grep "^instance_type" terraform.tfvars
[ "$(grep -c '^instance_type.*m6g.xlarge' terraform.tfvars)" = "1" ] || fail "tfvars did not update correctly"
ok "tfvars confirmed"

# -----------------------------------------------------------------------------
banner "STEP 3: Terraform plan + apply"
# -----------------------------------------------------------------------------

step "Running terraform plan"
terraform plan -out=/tmp/bump.tfplan -no-color | tail -20
ok "Plan saved"

step "Applying plan (auto-approved)"
terraform apply -auto-approve /tmp/bump.tfplan
ok "Terraform apply completed"

# -----------------------------------------------------------------------------
banner "STEP 4: Get current EC2 instance"
# -----------------------------------------------------------------------------

OLD_INSTANCE=$(aws ec2 describe-instances --region $REGION \
  --filters "Name=tag:Project,Values=petstore-otel-demo" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text)

if [ -z "$OLD_INSTANCE" ]; then
  fail "No running EC2 instance found - cluster may be empty"
fi

step "Current running instance(s)"
aws ec2 describe-instances --region $REGION \
  --filters "Name=tag:Project,Values=petstore-otel-demo" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].[InstanceId, InstanceType]" --output table

# -----------------------------------------------------------------------------
banner "STEP 5: Terminate old EC2"
# -----------------------------------------------------------------------------

step "Terminating $OLD_INSTANCE (ASG will launch replacement)"
aws ec2 terminate-instances --instance-ids $OLD_INSTANCE --region $REGION \
  --query 'TerminatingInstances[].[InstanceId, CurrentState.Name]' --output table

# -----------------------------------------------------------------------------
banner "STEP 6: Wait for new EC2 + ECS agent + task placement"
# -----------------------------------------------------------------------------

step "Waiting 90 seconds for new EC2 to launch and join cluster..."
sleep 90

step "Confirming new EC2 is up"
NEW_INSTANCE=""
for attempt in 1 2 3 4 5; do
  NEW_INSTANCE=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Project,Values=petstore-otel-demo" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" --output text)
  if [ -n "$NEW_INSTANCE" ] && [ "$NEW_INSTANCE" != "$OLD_INSTANCE" ]; then
    break
  fi
  echo "  Attempt $attempt: waiting 30 more seconds..."
  sleep 30
done

[ -n "$NEW_INSTANCE" ] || fail "No new EC2 launched after 4 minutes - check ASG"
ok "New EC2: $NEW_INSTANCE"

aws ec2 describe-instances --instance-ids $NEW_INSTANCE --region $REGION \
  --query 'Reservations[].Instances[].[InstanceId, InstanceType, State.Name]' --output table

step "Waiting 2 more minutes for ECS agent + task placement..."
sleep 120

# -----------------------------------------------------------------------------
banner "STEP 7: Verify cluster state"
# -----------------------------------------------------------------------------

step "Cluster overview"
aws ecs describe-clusters --clusters $CLUSTER --region $REGION \
  --query 'clusters[].[registeredContainerInstancesCount, runningTasksCount, pendingTasksCount]' \
  --output text

step "Per-service status"
aws ecs describe-services \
  --cluster $CLUSTER \
  --services postgres catalog-service payments-service orders-service api-gateway frontend \
  --region $REGION \
  --query "services[].[serviceName, runningCount, desiredCount, deployments[0].rolloutState]" \
  --output table

# -----------------------------------------------------------------------------
banner "STEP 8: Check ALB"
# -----------------------------------------------------------------------------

step "Frontend target health"
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw frontend_target_group_arn) \
  --region $REGION \
  --query "TargetHealthDescriptions[].[Target.Id, TargetHealth.State]" \
  --output table 2>/dev/null || echo "  (no targets registered yet)"

step "ALB health endpoint"
ALB_DNS=$(terraform output -raw alb_dns_name)
echo "  ALB URL: http://$ALB_DNS"
curl -sS -m 10 -o /tmp/alb-resp.txt -w "  HTTP status: %{http_code}\n  Response time: %{time_total}s\n" "http://$ALB_DNS/health" || echo "  (curl failed or timed out)"
[ -s /tmp/alb-resp.txt ] && echo "  Response body: $(cat /tmp/alb-resp.txt)"

# -----------------------------------------------------------------------------
banner "DONE"
# -----------------------------------------------------------------------------

cat <<-EOM

Summary:
- Old EC2 ($OLD_INSTANCE) terminated
- New EC2 ($NEW_INSTANCE) launched
- See per-service status above

Next steps:
- If all 6 services show 1/1 COMPLETED -> visit http://$ALB_DNS
- If any service is 0/1 -> check events:
    aws ecs describe-services --cluster $CLUSTER --services <name> \\
      --region $REGION --query "services[].events[0:5].message" --output text

EOM
