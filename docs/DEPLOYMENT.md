# Deployment Guide

This document provides step-by-step instructions for deploying the Invoice Document Storage infrastructure, applying the database schema, validating deployments, and performing rollbacks.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Deployment Order](#deployment-order)
- [Step 1: Bootstrap State Backend](#step-1-bootstrap-state-backend-one-time)
- [Step 2: Deploy QA](#step-2-deploy-qa)
- [Step 3: Deploy Stage](#step-3-deploy-stage)
- [Step 4: Deploy Prod](#step-4-deploy-prod)
- [Post-Deployment Tasks](#post-deployment-tasks)
- [CI/CD Pipeline](#cicd-pipeline)
- [Rollback Procedures](#rollback-procedures)
- [Promotion Workflow](#promotion-workflow)
- [Troubleshooting Deployment Issues](#troubleshooting-deployment-issues)

## Prerequisites

### Required Tools

| Tool | Minimum Version | Installation |
|---|---|---|
| Terraform | >= 1.7.0 | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |
| AWS CLI | >= 2.15 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| psql | >= 16 | `apt install postgresql-client-16` or `brew install postgresql@16` |
| Python | >= 3.11 | [python.org/downloads](https://www.python.org/downloads/) |
| jq | >= 1.6 | `apt install jq` or `brew install jq` |
| GitHub CLI | >= 2.0 | [cli.github.com](https://cli.github.com/) |

### Required IAM Permissions

The deploying principal (user or CI/CD role) requires the following permissions. In production, use a scoped IAM role rather than admin access.

| Service | Required Actions | Resource Scope |
|---|---|---|
| S3 | `s3:*` | `invoice-tfstate-*`, `invoice-docs-*` |
| DynamoDB | `dynamodb:*` | `invoice-tfstate-lock` |
| EC2 | `ec2:*` | VPC, subnets, security groups, endpoints, flow logs |
| Transfer Family | `transfer:*` | SFTP server, users, IAM roles |
| KMS | `kms:*` | Key creation, alias management, policy updates |
| RDS | `rds:*` | Aurora cluster, instances, parameter groups, proxy |
| IAM | `iam:*` | Role and policy management |
| SNS | `sns:*` | Topic creation, subscriptions |
| CloudWatch | `cloudwatch:*` | Alarms, dashboards |
| CloudWatch Logs | `logs:*` | Log group creation, encryption, subscription filters |
| Firehose | `firehose:*` | Delivery stream creation (Splunk streaming) |
| Secrets Manager | `secretsmanager:GetSecretValue` | RDS Proxy configuration, credential retrieval |
| STS | `sts:GetCallerIdentity` | Account ID resolution |

### Pre-Deployment Checklist

- [ ] AWS CLI configured with appropriate credentials (`aws sts get-caller-identity`)
- [ ] Terraform installed and in PATH (`terraform version`)
- [ ] psql available (`psql --version`)
- [ ] `terraform.tfvars` updated in each environment with actual values:
  - `aws_account_id` — Your 12-digit AWS account ID
  - `alert_email` — Email for CloudWatch alarm notifications
  - `cost_center` — Your organization's cost center identifier
  - `splunk_hec_endpoint` — Splunk HEC endpoint URL (empty string to skip Splunk)
  - `splunk_hec_token` — Splunk HEC token per environment (routes to env-specific index)
- [ ] Network connectivity to AWS APIs (or VPN if required)

## Deployment Order

Deployments **must** follow this sequence due to resource dependencies:

```
shared/state-backend → qa → stage → prod
```

**Rules:**
- Never deploy Prod before Stage is validated
- Never skip the state backend bootstrap on a fresh account
- Always run `terraform plan` and review output before `terraform apply`
- Always use plan files (`-out=env.tfplan`) to ensure what you reviewed is what gets applied

## Step 1: Bootstrap State Backend (One-time)

The state backend creates an S3 bucket and DynamoDB table for storing Terraform state. This is deployed once per AWS account and shared across all environments.

```bash
cd terraform/shared/state-backend

# Initialize (local state for the backend itself)
terraform init

# Review the plan
terraform plan \
  -var="aws_account_id=YOUR_ACCOUNT_ID" \
  -out=state-backend.tfplan

# Apply
terraform apply state-backend.tfplan
```

**What gets created:**
- S3 bucket: `invoice-tfstate-{account_id}` (versioning enabled, AES-256 encryption, `prevent_destroy` lifecycle)
- DynamoDB table: `invoice-tfstate-lock` (PAY_PER_REQUEST, PITR enabled, `prevent_destroy` lifecycle)
- Bucket policy: HTTPS-only access, deletion denied for non-admin principals

**Important:** The state backend itself uses local state (stored in the `terraform.tfstate` file in this directory). Do not delete this file. Consider storing it in a secure location (e.g., encrypted S3 bucket managed manually).

### Verify State Backend

```bash
# Verify S3 bucket exists and has versioning
aws s3api get-bucket-versioning \
  --bucket "invoice-tfstate-YOUR_ACCOUNT_ID"

# Verify DynamoDB table exists
aws dynamodb describe-table \
  --table-name invoice-tfstate-lock \
  --query 'Table.TableStatus'
```

## Step 2: Deploy QA

```bash
cd terraform/envs/qa

# Update terraform.tfvars with your actual values:
#   aws_account_id = "123456789012"
#   alert_email    = "team@example.com"

# Initialize (downloads providers, configures S3 backend)
terraform init

# Validate HCL syntax and module references
terraform validate

# Create and review the plan
terraform plan -out=qa.tfplan
```

**Review the plan output carefully:**
- Verify the expected number of resources will be created (~40-50 for a fresh deploy)
- Confirm no unexpected `destroy` or `replace` actions
- Check that all resource names contain `-qa-` suffix

```bash
# Apply the reviewed plan
terraform apply qa.tfplan
```

### Post-Deploy: Apply Database Schema (QA)

```bash
# Retrieve Aurora credentials from Secrets Manager
SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text)

DB_HOST=$(echo "$SECRET" | jq -r '.host')
DB_USER=$(echo "$SECRET" | jq -r '.username')
DB_PASS=$(echo "$SECRET" | jq -r '.password')

# Apply the schema
PGPASSWORD="$DB_PASS" psql \
  -h "$DB_HOST" \
  -U "$DB_USER" \
  -d postgres \
  -f ../../../database/schema.sql

# Verify schema was applied
PGPASSWORD="$DB_PASS" psql \
  -h "$DB_HOST" \
  -U "$DB_USER" \
  -d postgres \
  -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'invoice_docs' ORDER BY table_name;"
```

**Expected tables:** `collection_letter_details`, `documents`, `documents_default`, `documents_y2015` through `documents_y2027` (auto-created next year), `invoice_details`

### Post-Deploy: Run Smoke Test (QA)

```bash
bash scripts/smoke-test.sh qa
```

The smoke test validates:
1. S3 write with SSE-KMS encryption
2. Secrets Manager access for Aurora credentials
3. Aurora PostgreSQL connectivity (`SELECT 1`)
4. CloudWatch alarms exist and are in expected state

### Post-Deploy: Confirm SNS Subscription

After the first deployment, AWS sends a confirmation email to the `alert_email` address. **You must click the confirmation link** in that email for alarms to deliver notifications.

```bash
# Check subscription status
aws sns list-subscriptions-by-topic \
  --topic-arn $(terraform output -raw sns_topic_arn) \
  --query 'Subscriptions[*].{Endpoint:Endpoint,Status:SubscriptionArn}'
```

If the status shows `PendingConfirmation`, the email has not been confirmed yet.

## Step 3: Deploy Stage

```bash
cd terraform/envs/stage

# Update terraform.tfvars (same placeholders as QA)
terraform init
terraform validate
terraform plan -out=stage.tfplan

# Review plan — verify RDS Proxy is included (enable_rds_proxy = true)
terraform apply stage.tfplan
```

Repeat the database schema application, smoke test, and SNS confirmation for Stage.

### Stage-Specific Validation

Stage mirrors Prod topology (RDS Proxy, 2 instances, deletion protection). Validate:

```bash
# Verify RDS Proxy is running
aws rds describe-db-proxies \
  --query 'DBProxies[?DBProxyName==`invoice-proxy-stage`].{Status:Status,Endpoint:Endpoint}'

# Verify deletion protection is ON
aws rds describe-db-clusters \
  --db-cluster-identifier invoice-aurora-stage \
  --query 'DBClusters[0].DeletionProtection'

# Verify 2 Aurora instances
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=invoice-aurora-stage" \
  --query 'DBInstances[*].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass}'
```

## Step 4: Deploy Prod

```bash
cd terraform/envs/prod

# Update terraform.tfvars
terraform init
terraform validate
terraform plan -out=prod.tfplan
```

### Production Pre-Apply Review Checklist

Before applying to production, verify the plan output shows:

- [ ] No unexpected resource deletions or replacements
- [ ] No changes to KMS keys that could cause data loss
- [ ] No changes to S3 bucket settings that could affect Object Lock
- [ ] Security group changes do not break existing connectivity
- [ ] Aurora changes do not trigger an engine restart or failover
- [ ] VPC endpoint changes do not disrupt service connectivity

```bash
# Apply only after thorough review
terraform apply prod.tfplan
```

Repeat the database schema application and smoke test for Prod.

### Prod-Specific Validation

```bash
# Verify 3 AZs
aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=invoice-app-subnet-prod-*" \
  --query 'Subnets[*].{AZ:AvailabilityZone,CIDR:CidrBlock}'

# Verify Object Lock is enabled
aws s3api get-object-lock-configuration \
  --bucket invoice-docs-prod

# Verify SFTP server is running
aws transfer describe-server \
  --server-id $(terraform output -raw sftp_server_id) \
  --query '{State:State,Endpoint:EndpointDetails}'

# Verify landing zone bucket exists
aws s3api head-bucket --bucket invoice-landing-prod

# Verify VPC endpoints (6 total: S3 Gateway + 5 Interface)
aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Name,Values=invoice-*-endpoint-prod" \
  --query 'VpcEndpoints[*].{Name:Tags[?Key==`Name`].Value|[0],State:State,Type:VpcEndpointType}'

# Verify backup retention is 35 days
aws rds describe-db-clusters \
  --db-cluster-identifier invoice-aurora-prod \
  --query 'DBClusters[0].BackupRetentionPeriod'

# Verify Firehose delivery stream (if Splunk enabled)
aws firehose describe-delivery-stream \
  --delivery-stream-name "invoice-logs-to-splunk-prod" \
  --query 'DeliveryStreamDescription.{Status:DeliveryStreamStatus,Destination:Destinations[0].SplunkDestinationDescription.HECEndpoint}' \
  2>/dev/null || echo "Splunk streaming not configured"

# Verify file notification SNS topic exists
aws sns get-topic-attributes \
  --topic-arn $(terraform output -raw file_notification_sns_topic_arn) \
  --query 'Attributes.TopicArn'
```

## Post-Deployment Tasks

### Apply Migration Helpers (Optional)

If performing a legacy migration, apply the validation queries:

```bash
PGPASSWORD="$DB_PASS" psql \
  -h "$DB_HOST" \
  -U "$DB_USER" \
  -d postgres \
  -f ../../../database/migration_helpers.sql
```

### Set Up Cost Tracking

Follow the instructions in [COST_TRACKING.md](COST_TRACKING.md) to:
1. Create AWS Budget alerts for each environment
2. Set up Cost Anomaly Detection
3. Configure Cost Explorer filters by CostCenter and Environment tags

### Configure GitHub Actions (CI/CD)

1. Create an OIDC identity provider in your AWS account for GitHub Actions
2. Create per-environment IAM roles with the required permissions
3. Add GitHub repository secrets:
   - `AWS_ROLE_ARN_qa` — ARN of the QA deployment role
   - `AWS_ROLE_ARN_stage` — ARN of the Stage deployment role
   - `AWS_ROLE_ARN_prod` — ARN of the Prod deployment role
4. Create GitHub Environments (`qa`, `stage`, `prod`) with required reviewers on `prod`

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/terraform-plan.yml`) automates the plan/apply cycle:

### On Pull Request

1. **Detect** which environments are affected by the changed files
2. **Format check** — `terraform fmt -check -recursive`
3. **Security scan** — tfsec static analysis
4. **Plan** — `terraform plan` for each affected environment, output commented on the PR
5. **Artifact** — Plan file uploaded for use during apply

### On Merge to Main

1. **Apply** — Downloads the saved plan artifact and runs `terraform apply` with the exact plan that was reviewed
2. **Sequential** — Environments are applied one at a time (`max-parallel: 1`)
3. **Approval gate** — The `environment` field on the apply job integrates with GitHub Environment protection rules. Configure required reviewers on the `prod` environment.

**Important:** The apply step uses the saved plan file from the PR, ensuring no drift between what was reviewed and what gets applied. This is safer than re-running `terraform plan` at apply time.

## Rollback Procedures

### Destroying an Environment (QA)

QA has no deletion protection, so it can be destroyed directly:

```bash
cd terraform/envs/qa
terraform destroy
```

### Destroying an Environment (Stage/Prod)

Stage and Prod have deletion protection enabled on Aurora. You must disable it first:

```bash
# 1. Disable deletion protection
aws rds modify-db-cluster \
  --db-cluster-identifier invoice-aurora-<env> \
  --no-deletion-protection

# 2. Wait for modification to complete
aws rds wait db-cluster-available \
  --db-cluster-identifier invoice-aurora-<env>

# 3. Destroy (a final snapshot is created automatically)
cd terraform/envs/<env>
terraform destroy
```

### Reverting a Partial Apply

If `terraform apply` fails partway through:

```bash
# 1. Check what was actually created
terraform state list

# 2. If a resource is in a bad state, remove from state and re-import
terraform state rm <resource_address>
terraform import <resource_address> <resource_id>

# 3. Re-run plan and apply to converge
terraform plan -out=fix.tfplan
terraform apply fix.tfplan
```

### Reverting to a Previous Version

If you need to undo a Terraform change after a successful apply:

```bash
# 1. Revert the code change (git revert or manual)
git revert HEAD

# 2. Plan against the reverted code
terraform plan -out=revert.tfplan

# 3. Review the plan — verify it undoes the previous change
terraform apply revert.tfplan
```

### Stuck State Lock

If the DynamoDB state lock gets stuck (e.g., from a crashed apply or network failure):

```bash
# 1. Identify the lock holder
aws dynamodb get-item \
  --table-name invoice-tfstate-lock \
  --key '{"LockID": {"S": "invoice-tfstate-YOUR_ACCOUNT_ID/<env>/terraform.tfstate"}}'

# 2. Verify the lock holder is no longer running (check the "Info" field for process ID)

# 3. Force-unlock (use the lock ID from the error message)
terraform force-unlock <lock-id>
```

**Alternative (manual DynamoDB deletion):**

```bash
aws dynamodb delete-item \
  --table-name invoice-tfstate-lock \
  --key '{"LockID": {"S": "invoice-tfstate-YOUR_ACCOUNT_ID/<env>/terraform.tfstate"}}'
```

### Aurora Point-in-Time Restore

If the database is corrupted or data was accidentally deleted, perform a PITR restore. See [OPERATIONS.md](OPERATIONS.md) runbook #4 for detailed steps.

## Promotion Workflow

### Change Review Process

1. Create a feature branch from `main`
2. Make changes in `terraform/modules/` or `terraform/envs/<env>/`
3. Open a PR targeting `main`
4. CI automatically runs:
   - `terraform fmt -check`
   - `tfsec` security scan
   - `terraform plan` for affected environments
5. Plan output is posted as a PR comment for review
6. Reviewer verifies plan shows expected changes
7. Merge to `main` triggers sequential apply

### Promotion Checklist

Before promoting changes from QA to Stage to Prod:

- [ ] Changes applied successfully in QA
- [ ] Smoke test passes in QA (`bash scripts/smoke-test.sh qa`)
- [ ] Changes applied successfully in Stage
- [ ] Smoke test passes in Stage (`bash scripts/smoke-test.sh stage`)
- [ ] `terraform plan` reviewed for Prod (no unexpected changes)
- [ ] Stakeholders notified of Prod changes
- [ ] Prod apply scheduled during maintenance window (if applicable)
- [ ] Post-apply smoke test passes in Prod
- [ ] CloudWatch alarms in OK state
- [ ] SNS alert email confirmed (first deploy only)

## Troubleshooting Deployment Issues

### terraform init fails with "backend configuration changed"

```bash
# Re-initialize with migration flag
terraform init -migrate-state
```

### "Error acquiring the state lock"

See [Stuck State Lock](#stuck-state-lock) above.

### "Error: creating S3 Bucket: BucketAlreadyExists"

S3 bucket names are globally unique. If the bucket was manually deleted but still shows in state:

```bash
terraform state rm module.s3_documents.aws_s3_bucket.documents
terraform import module.s3_documents.aws_s3_bucket.documents invoice-docs-<env>
```

### "Error: creating RDS Cluster: DBClusterAlreadyExistsFault"

The cluster exists but isn't in Terraform state. Import it:

```bash
terraform import module.aurora_postgres.aws_rds_cluster.main invoice-aurora-<env>
```

### Plan shows "forces replacement" on Aurora cluster

Check what attribute triggers the replacement. Common causes:
- `engine_version` change (minor version upgrades are safe, major versions force replacement)
- `kms_key_id` change (encryption key changes require a new cluster)
- `master_username` change (cannot be modified in-place)

If the replacement is unintended, revert the change in `terraform.tfvars`.

### SNS subscription stuck in PendingConfirmation

```bash
# Re-send the confirmation email
aws sns subscribe \
  --topic-arn $(terraform output -raw sns_topic_arn) \
  --protocol email \
  --notification-endpoint your-email@example.com
```

Check spam/junk folders for the AWS SNS confirmation email.
