# Invoice Document Storage

AWS infrastructure for storing invoice documents (PDFs) in S3 with metadata in
Aurora PostgreSQL, replacing a legacy Windows file share and SQL Server database.

## Prerequisites

| Tool | Version |
|---|---|
| Terraform | >= 1.7.0 |
| AWS CLI | >= 2.15 |
| psql | >= 16 |
| Python | >= 3.11 |
| jq | >= 1.6 |

## Quick Start (Deploy QA)

```bash
# 1. Bootstrap state backend (one-time)
cd terraform/shared/state-backend
terraform init && terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID"

# 2. Deploy QA environment
cd ../../../terraform/envs/qa
# Edit terraform.tfvars with your aws_account_id and alert_email
terraform init && terraform validate && terraform plan -out=qa.tfplan
terraform apply qa.tfplan

# 3. Apply database schema
# (see docs/DEPLOYMENT.md for credential retrieval steps)
psql -h <aurora-endpoint> -U invoice_admin -d postgres -f database/schema.sql

# 4. Run smoke test
bash scripts/smoke-test.sh qa
```

## Environment Differences

| Setting | QA | Stage | Prod |
|---|---|---|---|
| VPC CIDR | 10.10.0.0/16 | 10.20.0.0/16 | 10.30.0.0/16 |
| Availability Zones | 2 | 2 | 3 |
| NAT Gateways | 0 | 1 | 3 |
| Aurora Instance | db.t4g.medium x1 | db.t4g.large x2 | db.r8g.large x2 |
| RDS Proxy | No | Yes | Yes |
| S3 Object Lock | No | No | Yes (GOVERNANCE, 10yr) |
| Backup Retention | 7 days | 14 days | 35 days |
| Log Retention | 90 days | 90 days | 365 days |

## Terraform Modules

| Module | Description |
|---|---|
| `networking` | VPC, subnets, NAT gateways, VPC endpoints, security groups |
| `kms` | KMS key with rotation, alias, and key policy |
| `s3_documents` | S3 bucket with versioning, encryption, lifecycle, and Object Lock |
| `aurora_postgres` | Aurora PostgreSQL 16 cluster, instances, RDS Proxy |
| `iam` | Ingestion roles (Lambda + ECS), migration role, shared policy |
| `monitoring` | CloudWatch log groups, alarms, SNS alerts, dashboard |

## S3 Key Convention

All document objects use this key format:

```
{source_system}/{year}/{month}/{account_id}/{document_uuid}.pdf
```

Example: `billing_system/2024/03/ACC-00123456/d4e5f6a7-b8c9-1234-5678-abcdef012345.pdf`

## Promotion Workflow

```
QA → Stage → Prod
```

1. Apply and validate changes in QA
2. Apply and validate in Stage
3. Run `terraform plan` against Prod and review
4. Apply to Prod during maintenance window
5. Run smoke test: `bash scripts/smoke-test.sh prod`

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for detailed steps.

## Documentation

| Document | Description |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System diagrams, data flow, security boundaries |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Deployment guide, rollback procedures |
| [OPERATIONS.md](docs/OPERATIONS.md) | Runbooks for common operational tasks |
| [COST_TRACKING.md](docs/COST_TRACKING.md) | Cost estimates, budgets, optimization |
| [CUTOVER_CHECKLIST.md](migration/CUTOVER_CHECKLIST.md) | Migration cutover procedure |
| [DataSync Setup](migration/datasync-setup.md) | File migration via AWS DataSync |

## Migration

The `migration/` directory contains tools for migrating from the legacy system:

- **`metadata_etl.py`** — ETL script to migrate metadata from SQL Server to Aurora
- **`datasync-setup.md`** — Guide for migrating files via AWS DataSync
- **`CUTOVER_CHECKLIST.md`** — Step-by-step cutover procedure

```bash
# Example: dry-run migration
python migration/metadata_etl.py \
  --env qa \
  --source billing_system \
  --table-pattern "Invoices_{year}" \
  --document-kind invoice \
  --year 2020 \
  --dry-run
```
