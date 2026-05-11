# Persistent Terraform Stack

Long-lived AWS resources for the petstore-otel-demo project:

- **5 ECR repositories** — one per service image (frontend, api-gateway, catalog-service, orders-service, payments-service)
- **1 Secrets Manager secret** — holds the Coralogix Send-Your-Data API key

This stack is **applied once** and kept around. The "ephemeral" stack (VPC/ECS/RDS/ALB) is what you spin up and tear down per session.

## Cost

- ECR storage: ~$0.10/GB/month, our images total ~500MB → ~$0.05/month
- Secrets Manager: $0.40/month per secret → $0.40/month
- **Total: ~$0.45/month**

## Apply (one-time)

```bash
cd terraform/persistent

# Copy the tfvars template and edit if needed
cp terraform.tfvars.example terraform.tfvars

# Initialize provider plugins
terraform init

# Preview what will be created (always do this first)
terraform plan

# Apply
terraform apply
```

Type `yes` when Terraform asks for confirmation.

## Set the Coralogix API key value

Terraform creates the secret resource but does NOT set its value (intentionally — secrets shouldn't be in tfstate or version control). Set it manually:

```bash
aws secretsmanager put-secret-value \
  --secret-id petstore-otel-demo/coralogix_private_key \
  --secret-string "cxtp_YOUR_ACTUAL_KEY_HERE" \
  --region eu-north-1
```

Verify (without revealing the value):

```bash
aws secretsmanager describe-secret \
  --secret-id petstore-otel-demo/coralogix_private_key \
  --region eu-north-1 | grep LastChangedDate
```

## Show the outputs (ECR URLs, secret ARN)

```bash
terraform output
```

You'll need these later for:
- `docker push` — use the ECR URLs from `ecr_repository_urls`
- ECS task definitions — use `coralogix_secret_arn`

## Build & push images

After this stack is applied, build and push your service images:

```bash
# Authenticate Docker to ECR (token expires in 12 hours)
aws ecr get-login-password --region eu-north-1 | \
  docker login --username AWS --password-stdin \
  $(terraform output -raw ecr_registry_url)

# Build and push each service. Run from the repo root.
cd ../..  # back to repo root

for SERVICE in frontend api-gateway catalog-service orders-service payments-service; do
  ECR_URL=$(cd terraform/persistent && terraform output -json ecr_repository_urls | jq -r ".\"$SERVICE\"")

  docker buildx build \
    --platform linux/arm64 \
    -t $ECR_URL:latest \
    --push \
    services/$SERVICE
done
```

`--platform linux/arm64` is critical because we're targeting Graviton EC2 instances. Apple Silicon Macs build ARM64 natively.

## Tear down (rare — only when you're done with the project entirely)

```bash
terraform destroy
```

This removes ECR repos AND the secret. Be sure you actually want this — re-creating means re-pushing all 5 images.
