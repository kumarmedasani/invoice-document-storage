# Deployment Guide

## Prerequisites

| Tool | Minimum Version | Purpose |
|---|---|---|
| Terraform | >= 1.7.0 | Infrastructure provisioning |
| AWS CLI | >= 2.15 | AWS resource management |
| psql | >= 16 | PostgreSQL client |
| Python | >= 3.11 | Migration ETL script |
| jq | >= 1.6 | JSON processing |

### Required IAM Permissions

The deploying principal (user or CI/CD role) requires:

- `s3:*` on the state bucket (`invoice-tfstate-*`)
- `dynamodb:*` on the lock table (`invoice-tfstate-lock`)
- `ec2:*` (VPC, subnets, security groups, endpoints, NAT gateways, EIPs)
- `kms:*` (key creation, alias management, policy updates)
- `s3:*` on document buckets (`invoice-docs-*`)
- `rds:*` (Aurora cluster, instances, parameter groups, proxy)
- `iam:*` (role and policy management)
- `sns:*` (topic creation, subscriptions)
- `cloudwatch:*` (alarms, dashboards, log groups)
- `logs:*` (log group creation)
- `secretsmanager:GetSecretValue` (for RDS Proxy configuration)
- `sts:GetCallerIdentity` (for account ID resolution)

## Deployment Order

Deployments **must** follow this sequence:

```
shared/state-backend → qa → stage → prod
```

**Never apply Prod before Stage is validated.**

## Step 1: Bootstrap State Backend (One-time)

```bash
cd terraform/shared/state-backend

# Edit variables or pass them inline
terraform init
terraform plan -var="aws_account_id=YOUR_ACCOUNT_ID"
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID"
```

After this completes, the S3 bucket and DynamoDB table exist for remote state.

## Step 2: Deploy QA

```bash
cd terraform/envs/qa

# Update terraform.tfvars with your actual values:
#   aws_account_id, alert_email

terraform init
terraform validate
terraform plan -out=qa.tfplan

# Review plan output — verify no unexpected destroys
terraform apply qa.tfplan
```

### Post-deploy: Apply Database Schema

```bash
# Fetch Aurora credentials
SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)
DB_HOST=$(echo $SECRET | jq -r '.host')
DB_USER=$(echo $SECRET | jq -r '.username')
DB_PASS=$(echo $SECRET | jq -r '.password')

# Apply schema
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres -f database/schema.sql
```

### Post-deploy: Run Smoke Test

```bash
bash scripts/smoke-test.sh qa
```

## Step 3: Deploy Stage

```bash
cd terraform/envs/stage
terraform init
terraform validate
terraform plan -out=stage.tfplan
terraform apply stage.tfplan
```

Repeat the database schema application and smoke test for Stage.

## Step 4: Deploy Prod

```bash
cd terraform/envs/prod
terraform init
terraform validate
terraform plan -out=prod.tfplan

# CRITICAL: Review plan carefully before applying to production
terraform apply prod.tfplan
```

Repeat the database schema application and smoke test for Prod.

## Rollback Procedures

### Destroying an Environment Cleanly

For QA (no deletion protection):

```bash
cd terraform/envs/qa
terraform destroy
```

For Stage/Prod (deletion protection enabled):

1. Disable deletion protection on Aurora:
   ```bash
   aws rds modify-db-cluster \
     --db-cluster-identifier invoice-aurora-<env> \
     --no-deletion-protection
   ```
2. Run destroy (a final snapshot will be created automatically):
   ```bash
   terraform destroy
   ```

### Reverting a Partial Apply

If `terraform apply` fails partway through:

1. Check current state:
   ```bash
   terraform state list
   ```
2. If a resource is in a bad state, remove it from state and re-import:
   ```bash
   terraform state rm <resource_address>
   terraform import <resource_address> <resource_id>
   ```
3. Re-run plan and apply:
   ```bash
   terraform plan -out=fix.tfplan
   terraform apply fix.tfplan
   ```

### Stuck State Lock

If the DynamoDB state lock gets stuck (e.g., from a crashed apply):

1. Identify the lock:
   ```bash
   aws dynamodb get-item \
     --table-name invoice-tfstate-lock \
     --key '{"LockID": {"S": "invoice-tfstate-123456789012/<env>/terraform.tfstate"}}'
   ```
2. Remove the lock:
   ```bash
   aws dynamodb delete-item \
     --table-name invoice-tfstate-lock \
     --key '{"LockID": {"S": "invoice-tfstate-123456789012/<env>/terraform.tfstate"}}'
   ```
3. Re-run your Terraform command.

## Promoting from QA to Stage to Prod

### Change Review Process

1. Make changes in `terraform/modules/` or `terraform/envs/qa/`
2. Open a PR targeting the `main` branch
3. CI runs `terraform fmt -check` and `terraform plan` for affected environments
4. Reviewer verifies plan output shows expected changes
5. Merge to `main` triggers apply for the affected environment

### Running Plan Against Prod Before Applying

```bash
cd terraform/envs/prod
terraform plan -out=prod.tfplan

# Review the plan output for:
# - No unexpected resource deletions
# - No changes to KMS keys or S3 bucket settings that could cause data loss
# - Security group changes do not break connectivity
# - Aurora changes do not trigger a restart

# Only after review:
terraform apply prod.tfplan
```

### Promotion Checklist

- [ ] Changes applied and validated in QA
- [ ] Changes applied and validated in Stage
- [ ] `terraform plan` run against Prod and reviewed
- [ ] Stakeholders notified of Prod changes
- [ ] Prod apply executed during maintenance window (if applicable)
- [ ] Post-apply smoke test passes
