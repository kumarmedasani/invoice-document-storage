# Invoice Document Storage

AWS infrastructure for storing invoice documents (PDFs) in S3 with metadata in Aurora PostgreSQL, replacing a legacy Windows file share and SQL Server database.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start-deploy-qa)
- [Repository Structure](#repository-structure)
- [Environment Differences](#environment-differences)
- [Terraform Modules](#terraform-modules)
- [S3 Key Convention](#s3-key-convention)
- [Database Schema](#database-schema)
- [Migration Tooling](#migration-tooling)
- [CI/CD Pipeline](#cicd-pipeline)
- [Promotion Workflow](#promotion-workflow)
- [Documentation Index](#documentation-index)

## Overview

This project provides a complete infrastructure-as-code (Terraform) solution for migrating from a legacy Windows Server-based document storage system to AWS. The legacy system uses a Windows file share for PDF storage and SQL Server for metadata. The new system uses:

- **Amazon S3** for document (PDF) storage with lifecycle tiering (Standard -> Glacier -> Deep Archive) and optional Object Lock for compliance
- **Aurora PostgreSQL 16** for metadata storage with partitioned tables, managed credentials, and optional RDS Proxy
- **AWS KMS** for encryption at rest across all services (S3, Aurora, Secrets Manager, CloudWatch Logs)
- **AWS Transfer Family (SFTP)** for vendor file ingestion into a landing zone S3 bucket, with Lambda processing (ZIP extraction) into the documents bucket
- **VPC** with private-only subnets, VPC endpoints (S3 Gateway, Secrets Manager, KMS, CloudWatch, STS), no internet egress, and VPC Flow Logs
- **CloudWatch** for monitoring with 6 metric alarms, a unified dashboard, and KMS-encrypted log groups
- **Kinesis Data Firehose** for streaming all CloudWatch Logs to Splunk (per-environment index via HEC token)
- **SNS** for infrastructure alerting and file drop notifications (external systems subscribe for customer email)

The platform is designed to be **source-system agnostic** — any document source system can be integrated by providing a source system name. There are no hardcoded system names; source systems are configured via CLI arguments and stored as `VARCHAR(50)` in the database.

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Source system as VARCHAR, not ENUM | Supports any source system without schema changes |
| KMS key policy delegates to IAM | Breaks circular dependency between KMS and IAM modules |
| S3 bucket name passed as string to monitoring | Breaks circular dependency between S3 and Monitoring modules |
| Trigger-based FK enforcement | PostgreSQL 16 does not support standard FK references to partitioned tables without partition key |
| Separate access logging bucket | Audit trail for document bucket access without self-referencing logging |
| RDS Proxy in Stage/Prod only | Connection pooling and failover not needed for QA development workloads |

## Prerequisites

| Tool | Minimum Version | Purpose |
|---|---|---|
| Terraform | >= 1.7.0 | Infrastructure provisioning |
| AWS CLI | >= 2.15 | AWS resource management |
| psql | >= 16 | PostgreSQL client for schema deployment |
| Python | >= 3.11 | Migration ETL script |
| jq | >= 1.6 | JSON processing in scripts |
| GitHub CLI (`gh`) | >= 2.0 | PR creation and CI/CD interaction |

### AWS Account Requirements

- An AWS account with appropriate IAM permissions (see [DEPLOYMENT.md](docs/DEPLOYMENT.md))
- OIDC identity provider configured for GitHub Actions (for CI/CD)
- Per-environment IAM roles stored as GitHub secrets (`AWS_ROLE_ARN_qa`, `AWS_ROLE_ARN_stage`, `AWS_ROLE_ARN_prod`)
- SNS email subscription confirmation (sent automatically on first deploy)

## Quick Start (Deploy QA)

```bash
# 1. Bootstrap state backend (one-time, requires admin credentials)
cd terraform/shared/state-backend
terraform init && terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID"

# 2. Deploy QA environment
cd ../../envs/qa
# Edit terraform.tfvars: set aws_account_id, alert_email
terraform init && terraform validate && terraform plan -out=qa.tfplan
terraform apply qa.tfplan

# 3. Apply database schema
SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --query SecretString --output text)
DB_HOST=$(echo $SECRET | jq -r '.host')
DB_USER=$(echo $SECRET | jq -r '.username')
DB_PASS=$(echo $SECRET | jq -r '.password')
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
  -f ../../database/schema.sql

# 4. Run smoke test
bash ../../scripts/smoke-test.sh qa
```

## Repository Structure

```
invoice-document-storage/
├── .github/
│   └── workflows/
│       └── terraform-plan.yml          # CI/CD: plan on PR, apply on merge
├── database/
│   ├── schema.sql                      # Full PostgreSQL schema (partitioned)
│   └── migration_helpers.sql           # Validation queries and legacy_id_map view
├── docs/
│   ├── ARCHITECTURE.md                 # System diagrams, data flow, security
│   ├── COST_TRACKING.md                # Cost estimates, budgets, optimization
│   ├── DATABASE.md                     # Schema details, partitioning, roles
│   ├── DEPLOYMENT.md                   # Step-by-step deployment guide
│   ├── OPERATIONS.md                   # 15 operational runbooks
│   └── SECURITY.md                     # Security controls and compliance
├── migration/
│   ├── CUTOVER_CHECKLIST.md            # Migration cutover procedure
│   ├── datasync-setup.md              # AWS DataSync file migration guide
│   ├── metadata_etl.py                # Python ETL: SQL Server -> Aurora
│   └── requirements.txt              # Python dependencies
├── scripts/
│   └── smoke-test.sh                  # Post-deploy validation script
├── terraform/
│   ├── envs/
│   │   ├── qa/                        # QA environment config
│   │   ├── stage/                     # Stage environment config
│   │   └── prod/                      # Prod environment config
│   ├── modules/
│   │   ├── aurora_postgres/           # Aurora PostgreSQL cluster + RDS Proxy
│   │   ├── iam/                       # IAM roles and policies
│   │   ├── kms/                       # KMS key, alias, and policy
│   │   ├── monitoring/                # CloudWatch, SNS, dashboard
│   │   ├── networking/                # VPC, subnets, endpoints, security groups
│   │   ├── lambda_ingestion/          # Ingestion Lambda, SNS trigger, VPC config
│   │   ├── s3_documents/              # S3 bucket, lifecycle, Object Lock
│   │   └── transfer_family/           # SFTP server, landing zone bucket
│   └── shared/
│       └── state-backend/             # S3 + DynamoDB for Terraform state
├── .gitignore
└── README.md
```

## Environment Differences

| Setting | QA | Stage | Prod |
|---|---|---|---|
| VPC CIDR | 10.10.0.0/16 | 10.20.0.0/16 | 10.30.0.0/16 |
| Availability Zones | 2 | 2 | 3 |
| Internet Egress | None (VPC endpoints only) | None (VPC endpoints only) | None (VPC endpoints only) |
| Aurora Instance | db.t4g.medium x1 | db.t4g.large x2 | db.r8g.large x2 |
| Aurora Backup Retention | 7 days | 14 days | 35 days |
| RDS Proxy | No | Yes | Yes |
| Performance Insights | No | Yes | Yes |
| Deletion Protection | No | Yes | Yes |
| S3 Object Lock | No | No | Yes (GOVERNANCE, 10yr) |
| Log Retention | 90 days | 90 days | 365 days |
| Max Connections Alarm | 170 (80% of 212) | 272 (80% of 340) | 3200 (80% of 4000) |
| Cost Center | IT-1042 | IT-1042 | IT-1043 |

## Terraform Modules

The infrastructure is split into 8 modules with a clear dependency chain:

```
networking ──┐
             ├──> aurora_postgres ──┐
kms ─────────┤                     ├──> monitoring ──┬──> s3_documents ──┐
             └─────────────────────┘                 └──> transfer_family ──> iam ──> lambda_ingestion
```

| Module | Resources Created | Key Outputs |
|---|---|---|
| `networking` | VPC, app/data subnets, S3 Gateway Endpoint, 5 Interface Endpoints (Secrets Manager, KMS, CloudWatch, Logs, STS), 3 security groups, VPC Flow Logs | `vpc_id`, `app_subnet_ids`, `data_subnet_ids`, `sg_app_id`, `sg_aurora_id` |
| `kms` | KMS symmetric key (rotation enabled), alias `alias/invoice-{env}`, key policy with root admin, Aurora grant, CloudWatch Logs, and non-root deletion deny | `key_arn`, `key_id` |
| `aurora_postgres` | Aurora PostgreSQL 16.2 cluster, N instances, DB subnet group, parameter group (force SSL, logging), Enhanced Monitoring role, optional RDS Proxy with IAM role | `cluster_id`, `writer_endpoint`, `reader_endpoint`, `master_secret_arn` |
| `monitoring` | 3 CloudWatch log groups, 2 SNS topics (alerts + file notifications), 6 CloudWatch alarms, dashboard (6 widgets), Kinesis Firehose → Splunk (optional), subscription filters | `sns_topic_arn`, `file_notification_sns_topic_arn`, log group names, `dashboard_name`, `firehose_delivery_stream_name` |
| `s3_documents` | S3 bucket with versioning, SSE-KMS (bucket key), public access block, HTTPS-only policy, lifecycle rules (Standard->Glacier->Deep Archive->Expire), Object Lock (conditional), access logging bucket, SNS notification (conditional) | `bucket_id`, `bucket_arn` |
| `transfer_family` | AWS Transfer Family SFTP server, landing zone S3 bucket (`invoice-landing-{env}`) with SSE-KMS, 7-day expiry, S3 event notification → SNS, SFTP user/logging IAM roles | `sftp_server_endpoint`, `landing_bucket_arn`, `landing_bucket_name` |
| `iam` | Lambda ingestion role (cross-bucket: read+delete landing, read+write documents), migration role (DataSync + manual assume) | `lambda_role_arn`, `migration_role_arn` |
| `lambda_ingestion` | Lambda function (`invoice-ingestion-{env}`) with VPC config, SNS topic subscription, `AWSLambdaVPCAccessExecutionRole`, stub handler (replaced by CI/CD) | `function_name`, `function_arn` |

## S3 Key Convention

All document objects follow this key format:

```
{source_system}/{year}/{month}/{account_id}/{document_uuid}.pdf
```

**Examples:**
```
billing_system/2024/03/ACC-00123456/d4e5f6a7-b8c9-1234-5678-abcdef012345.pdf
erp_system/2023/11/CUST-789/a1b2c3d4-e5f6-7890-abcd-ef0123456789.pdf
```

- `source_system` — configurable identifier for the originating system (e.g., `billing_system`, `erp_system`)
- `year/month` — derived from the document's invoice/letter date
- `account_id` — the customer account identifier from the source system
- `document_uuid` — a UUID v4 generated during migration or ingestion (ensures uniqueness)

## Database Schema

The PostgreSQL schema (`invoice_docs`) includes:

- **`documents`** — Partitioned table (RANGE by `received_date`, yearly 2015-2026 + DEFAULT) storing document metadata, S3 location, and legacy mapping
- **`invoice_details`** — Invoice-specific fields (number, amount, dates, service address)
- **`collection_letter_details`** — Collection letter-specific fields (type, balance, sent method)
- **`create_yearly_partition()`** — Function to auto-create future yearly partitions
- **`enforce_document_fk()`** — Trigger-based FK enforcement (PG16 partitioned table workaround)
- **Roles:** `invoice_app` (SELECT/INSERT/UPDATE) and `invoice_readonly` (SELECT only)

See [DATABASE.md](docs/DATABASE.md) for full schema documentation.

## Migration Tooling

| Tool | Purpose |
|---|---|
| `migration/metadata_etl.py` | Python ETL script: extracts metadata from legacy SQL Server, transforms it, and loads into Aurora PostgreSQL. Supports any source system via `--source` flag. |
| `migration/datasync-setup.md` | Step-by-step guide for migrating PDF files from Windows file share to S3 via AWS DataSync |
| `migration/CUTOVER_CHECKLIST.md` | Production cutover procedure with rollback criteria |
| `database/migration_helpers.sql` | Validation queries for verifying migration integrity |

### ETL Usage Examples

```bash
# Dry run — validate without writing to Aurora
python migration/metadata_etl.py \
  --env qa --source billing_system \
  --table-pattern "Invoices_{year}" \
  --document-kind invoice --year 2020 --dry-run

# Full migration — all years
python migration/metadata_etl.py \
  --env prod --source billing_system \
  --table-pattern "Invoices_{year}" \
  --document-kind invoice --year all

# Collection letters with custom batch size
python migration/metadata_etl.py \
  --env stage --source collections \
  --table-pattern "CollectionLetters_{year}" \
  --document-kind collection_letter --year 2023 --batch-size 500
```

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/terraform-plan.yml`) provides:

1. **Environment Detection** — Automatically determines which environments are affected by changes
2. **Format Check** — Validates `terraform fmt` compliance
3. **Security Scan** — Runs tfsec static analysis on all Terraform code
4. **Plan** — Runs `terraform plan` for each affected environment, comments plan output on PRs
5. **Apply** — On merge to `main`, downloads the saved plan artifact and applies it (no re-plan drift risk)

The apply job uses GitHub Environments for approval gates. Configure required reviewers on the `prod` environment in your repository settings to enforce manual approval before production applies.

## Promotion Workflow

```
QA  ───>  Stage  ───>  Prod
```

1. Apply and validate changes in QA
2. Apply and validate in Stage (with RDS Proxy, same topology as Prod)
3. Open PR with changes, review `terraform plan` output for Prod
4. Merge to `main` — CI applies to affected environments sequentially
5. Run smoke test: `bash scripts/smoke-test.sh prod`

See [DEPLOYMENT.md](docs/DEPLOYMENT.md) for detailed deployment procedures.

## Documentation Index

| Document | Description |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System topology, data flow diagrams, storage lifecycle, security boundaries |
| [DATABASE.md](docs/DATABASE.md) | Schema design, partitioning strategy, roles, triggers, migration helpers |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Step-by-step deployment guide, rollback procedures, promotion checklist |
| [OPERATIONS.md](docs/OPERATIONS.md) | 15 operational runbooks for day-to-day tasks, SFTP, Splunk, and troubleshooting |
| [COST_TRACKING.md](docs/COST_TRACKING.md) | Cost estimates, AWS Budgets setup, anomaly detection, optimization tips |
| [SECURITY.md](docs/SECURITY.md) | Security controls, encryption, network isolation, IAM, compliance |
| [DataSync Setup](migration/datasync-setup.md) | File migration from Windows file share to S3 via AWS DataSync |
| [Cutover Checklist](migration/CUTOVER_CHECKLIST.md) | Production migration cutover procedure with rollback criteria |

## Values to Replace Before Deployment

| Placeholder | Location | Description |
|---|---|---|
| `aws_account_id` | `terraform.tfvars` (all envs) | Your AWS account ID |
| `alert_email` | `terraform.tfvars` (all envs) | Email for CloudWatch alarm notifications |
| `cost_center` | `terraform.tfvars` (all envs) | Your organization's cost center code |
| OIDC provider | GitHub repo settings | GitHub Actions OIDC provider in your AWS account |
| `splunk_hec_endpoint` | `terraform.tfvars` (all envs) | Splunk HEC endpoint URL (empty to disable) |
| `splunk_hec_token` | `terraform.tfvars` (all envs) | Splunk HEC token (per-env, routes to correct index) |
| `AWS_ROLE_ARN_*` | GitHub repo secrets | Per-environment IAM role ARNs for CI/CD |
