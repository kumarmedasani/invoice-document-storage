# Security

This document describes the security controls implemented in the Invoice Document Storage platform, covering encryption, network isolation, identity and access management, logging, and compliance considerations.

## Table of Contents

- [Security Overview](#security-overview)
- [Encryption at Rest](#encryption-at-rest)
- [Encryption in Transit](#encryption-in-transit)
- [Network Isolation](#network-isolation)
- [Identity and Access Management](#identity-and-access-management)
- [Secrets Management](#secrets-management)
- [Logging and Audit Trail](#logging-and-audit-trail)
- [Data Protection](#data-protection)
- [CI/CD Security](#cicd-security)
- [Terraform State Security](#terraform-state-security)
- [Incident Response](#incident-response)
- [Compliance Considerations](#compliance-considerations)

## Security Overview

The platform implements defense-in-depth with multiple layers of security:

| Layer | Controls |
|---|---|
| **Encryption** | KMS-managed keys for all data at rest; TLS/SSL enforced for all data in transit |
| **Network** | Private-only subnets, no public endpoints, VPC endpoints for AWS services, security group micro-segmentation, VPC Flow Logs |
| **Identity** | Least-privilege IAM roles per workload, no long-lived credentials, managed secret rotation |
| **Data** | S3 versioning, Object Lock (Prod), public access blocks, HTTPS-only bucket policy |
| **Monitoring** | CloudWatch alarms, SNS alerts, structured logging, access logging |
| **CI/CD** | OIDC authentication (no static keys), tfsec scanning, plan artifact review, environment approval gates |

## Encryption at Rest

### KMS Key Configuration

A single symmetric KMS key per environment encrypts all data at rest:

| Property | Value |
|---|---|
| Key type | Symmetric (AES-256) |
| Key rotation | Enabled (annual automatic rotation) |
| Deletion window | 30 days (non-root principals denied `kms:ScheduleKeyDeletion`) |
| Alias | `alias/invoice-{env}` |

### Services Using KMS Encryption

| Service | Encryption Type | Key |
|---|---|---|
| S3 Documents | SSE-KMS with S3 Bucket Keys | `alias/invoice-{env}` |
| Aurora PostgreSQL | Storage-level encryption | `alias/invoice-{env}` |
| Secrets Manager (Aurora credentials) | Envelope encryption | `alias/invoice-{env}` |
| CloudWatch Log Groups (3) | Log group encryption | `alias/invoice-{env}` |
| Performance Insights (Stage/Prod) | PI data encryption | `alias/invoice-{env}` |
| SNS Alert Topic | Topic encryption | `alias/invoice-{env}` |

### KMS Key Policy

The key policy uses the **root admin delegation** pattern to avoid circular dependencies:

```
Statement 1: Root Account Admin
  - Principal: arn:aws:iam::{account}:root
  - Action: kms:*
  - Purpose: Delegates permission control to IAM policies

Statement 2: Aurora CreateGrant
  - Principal: rds.amazonaws.com
  - Action: kms:CreateGrant, ListGrants, RevokeGrant
  - Condition: kms:GrantIsForAWSResource = true
  - Purpose: Allows Aurora to encrypt storage

Statement 3: CloudWatch Logs
  - Principal: logs.amazonaws.com
  - Action: kms:Encrypt, Decrypt, GenerateDataKey*, DescribeKey
  - Purpose: Allows CloudWatch to encrypt log data

Statement 4: Deny Non-Root Key Deletion
  - Principal: *
  - Action: kms:ScheduleKeyDeletion (DENY)
  - Condition: aws:PrincipalArn != root
  - Purpose: Prevents accidental key deletion
```

Each IAM role (ingestion, migration) receives KMS permissions (`kms:GenerateDataKey`, `kms:Decrypt`, `kms:DescribeKey`) via its IAM policy, not via the key policy.

### S3 Bucket Keys

S3 Bucket Keys are enabled (`bucket_key_enabled = true`), which:
- Reduces KMS API calls by ~99%
- Generates per-object keys locally using a bucket-level key
- Reduces KMS costs from ~$0.03/10K requests to near-zero
- Has no impact on security posture (same AES-256 encryption)

## Encryption in Transit

| Path | Protocol | Enforcement |
|---|---|---|
| Client -> S3 | HTTPS | Bucket policy: `Deny` when `aws:SecureTransport = false` |
| Client -> Aurora | PostgreSQL SSL | Cluster parameter: `rds.force_ssl = 1` |
| Client -> RDS Proxy | TLS | Proxy config: `require_tls = true` |
| App -> VPC Endpoints | HTTPS | Interface endpoints use TLS by default |
| VPC -> S3 Gateway Endpoint | HTTPS | AWS internal, encrypted in transit |

## Network Isolation

### No Public-Facing Resources

The platform has **zero public-facing resources**:
- No public subnets for application workloads
- No public IP addresses on any compute resource
- No S3 bucket with public access
- All AWS service access goes through VPC endpoints

### Subnet Tiers

| Tier | Internet Access | Purpose |
|---|---|---|
| App Subnets | Via NAT Gateway (Stage/Prod), None (QA) | Lambda/ECS ingestion |
| Data Subnets | **None** (no NAT route, no IGW route) | Aurora PostgreSQL, RDS Proxy |
| NAT Subnets | Public (minimal /28 CIDRs) | NAT Gateway placement only |

Data subnets have **no route to the internet** — they can only communicate with the VPC (app subnets, VPC endpoints).

### Security Group Rules

| Security Group | Direction | Port | Source/Destination | Purpose |
|---|---|---|---|---|
| sg-app | Egress | 443 | 0.0.0.0/0 | HTTPS to VPC endpoints, NAT |
| sg-app | Egress | 5432 | sg-aurora | PostgreSQL to Aurora |
| sg-aurora | Ingress | 5432 | sg-app | PostgreSQL from app only |
| sg-vpc-endpoints | Ingress | 443 | App subnet CIDRs | HTTPS from app subnets |

**Key constraints:**
- Aurora accepts connections **only** from the app security group (not from arbitrary IPs)
- VPC endpoints accept HTTPS only from app subnet CIDRs
- No ingress rules on the app security group (Lambda/ECS initiate all connections)

### S3 VPC Endpoint Policy

The S3 Gateway Endpoint has a **scoped policy** that restricts access to `invoice-docs-*` buckets only:

```json
{
  "Effect": "Allow",
  "Principal": "*",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::invoice-docs-*",
    "arn:aws:s3:::invoice-docs-*/*"
  ]
}
```

This prevents workloads in the VPC from accessing other S3 buckets through the endpoint.

### VPC Flow Logs

All VPC traffic (ACCEPT and REJECT) is logged to CloudWatch Logs:
- Log group: `/aws/vpc/invoice-vpc-{env}/flow-logs`
- Retention: 90 days
- Useful for: security investigation, connectivity debugging, compliance audits

## Identity and Access Management

### IAM Roles

| Role | Trust Principal | Permissions |
|---|---|---|
| `invoice-ingestion-lambda-{env}` | `lambda.amazonaws.com` | S3, KMS, Secrets Manager, CloudWatch Logs |
| `invoice-ingestion-ecs-{env}` | `ecs-tasks.amazonaws.com` | S3, KMS, Secrets Manager, CloudWatch Logs |
| `invoice-migration-{env}` | `datasync.amazonaws.com`, root account | S3, KMS |
| `invoice-aurora-monitoring-{env}` | `monitoring.rds.amazonaws.com` | Enhanced Monitoring |
| `invoice-rds-proxy-{env}` | `rds.amazonaws.com` | Secrets Manager, KMS (Stage/Prod only) |
| `invoice-vpc-flow-logs-{env}` | `vpc-flow-logs.amazonaws.com` | CloudWatch Logs |

### Least-Privilege Principles

1. **No wildcard resources** — All IAM policies scope permissions to specific resource ARNs (bucket ARN, key ARN, secret ARN, log group ARN pattern)
2. **No `s3:DeleteObject`** — The ingestion policy does not grant delete permissions; deletions are soft-deletes (status change to `'deleted'`)
3. **Separate roles per workload** — Lambda and ECS have distinct roles even though they share the same policy, allowing independent trust and audit
4. **Migration role is temporary** — The DataSync/ETL role can be removed after migration is complete

### Database Roles

| Role | Permissions | Purpose |
|---|---|---|
| `invoice_app` | SELECT, INSERT, UPDATE on all tables | Application ingestion service |
| `invoice_readonly` | SELECT on all tables | Reporting, BI tools |

**Key restrictions:**
- `invoice_app` has no DELETE permission — deletions are status updates (`status = 'deleted'`)
- `ALTER DEFAULT PRIVILEGES` ensures future tables automatically inherit grants
- No direct database login — roles are `NOLOGIN`; users are created separately and granted these roles

## Secrets Management

### Aurora Credentials

Aurora uses `manage_master_user_password = true`, which:
- Stores credentials in Secrets Manager automatically
- Encrypts the secret with the environment's KMS key
- Supports automatic rotation via RDS-managed rotation Lambda

### No Static Credentials

- **No IAM access keys** — All compute uses IAM roles (Lambda execution role, ECS task role)
- **No hardcoded passwords** — Aurora credentials are managed by Secrets Manager
- **CI/CD uses OIDC** — GitHub Actions authenticates via OpenID Connect, no static AWS keys

### Credential Caching

- Application services should cache Secrets Manager credentials for **no more than 5 minutes**
- RDS Proxy handles credential rotation transparently — the proxy maintains its own connection pool and refreshes credentials automatically

## Logging and Audit Trail

### Application Logs

| Log Source | Log Group | Format |
|---|---|---|
| Ingestion service | `/invoice/application/{env}` | Structured JSON |
| Aurora PostgreSQL | `/invoice/aurora/{env}` | PostgreSQL log format |
| Migration ETL | `/invoice/migration/{env}` | Structured JSON |
| VPC traffic | `/aws/vpc/invoice-vpc-{env}/flow-logs` | VPC Flow Log format |

### S3 Access Logs

The document bucket (`invoice-docs-{env}`) logs all access to a dedicated access logging bucket (`invoice-docs-{env}-access-logs`):

- Prefix: `s3-access-logs/`
- Retention: 90 days (auto-expire lifecycle rule)
- Logged operations: GET, PUT, DELETE, HEAD, LIST

### Aurora Audit Logging

Aurora parameter group enables:
- `log_connections = 1` — Logs every new connection
- `log_disconnections = 1` — Logs every disconnection
- `log_min_duration_statement = 1000` — Logs queries taking > 1 second

### CloudWatch Alarms as Audit Events

All alarm state transitions (ALARM, OK) are published to SNS, creating an audit trail of infrastructure health events.

## Data Protection

### S3 Document Protection

| Control | QA | Stage | Prod |
|---|---|---|---|
| Versioning | Enabled | Enabled | Enabled |
| Object Lock | No | No | GOVERNANCE mode, 3650 days |
| Public Access Block | All 4 blocks enabled | All 4 blocks enabled | All 4 blocks enabled |
| HTTPS-Only Policy | Yes | Yes | Yes |
| Access Logging | Yes | Yes | Yes |
| Lifecycle (expire) | 3650 days | 3650 days | 3650 days |

### Aurora Data Protection

| Control | QA | Stage | Prod |
|---|---|---|---|
| Storage Encryption | KMS | KMS | KMS |
| Force SSL | Yes | Yes | Yes |
| Deletion Protection | No | Yes | Yes |
| Final Snapshot on Delete | No (skip) | Yes | Yes |
| Backup Retention | 7 days | 14 days | 35 days |
| Enhanced Monitoring | 60s interval | 60s interval | 60s interval |

### State Backend Protection

| Control | Description |
|---|---|
| `prevent_destroy` lifecycle | S3 bucket and DynamoDB table cannot be destroyed by Terraform |
| Bucket versioning | State file versions preserved |
| HTTPS-only policy | Denies non-TLS access to state |
| Deletion deny policy | Non-admin principals cannot delete state objects |
| DynamoDB PITR | Point-in-time recovery enabled for the lock table |

## CI/CD Security

### OIDC Authentication

GitHub Actions authenticates to AWS using OpenID Connect — **no static AWS access keys** are stored as secrets:

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: us-east-1
```

### Security Scanning

The CI pipeline runs [tfsec](https://github.com/aquasecurity/tfsec) static analysis on all Terraform code. This catches:
- Unencrypted resources
- Overly permissive security groups
- Missing logging configurations
- IAM policy issues

### Plan Artifact Safety

The apply step uses the **saved plan artifact** from the PR review, not a fresh `terraform plan`. This prevents:
- Drift between review and apply
- Time-of-check to time-of-use (TOCTOU) issues
- Unreviewed changes reaching production

### Environment Protection

GitHub Environments should be configured with:
- **Required reviewers** on `prod` (manual approval before Prod apply)
- **Deployment branch restrictions** (only `main` can deploy)

## Terraform State Security

### State Backend

| Component | Protection |
|---|---|
| S3 Bucket | Versioning, AES-256 encryption, public access blocked, `prevent_destroy` |
| DynamoDB Lock Table | PITR enabled, `prevent_destroy` |
| Bucket Policy | HTTPS-only, non-admin deletion denied |

### Sensitive Data in State

Terraform state may contain sensitive values (e.g., RDS master password reference). Protections:
- State bucket has server-side encryption
- State bucket policy restricts access
- State bucket versioning allows recovery from corruption
- No state files committed to git (`.terraform/` and `*.tfstate` in `.gitignore`)

## Incident Response

### Credential Compromise

1. **Rotate Aurora credentials immediately:**
   ```bash
   aws secretsmanager rotate-secret --secret-id <arn> --rotate-immediately
   ```
2. Check VPC Flow Logs for unusual access patterns
3. Check S3 access logs for unauthorized object access
4. Review CloudWatch Logs for unexpected API calls

### KMS Key Compromise

1. **Do NOT disable or delete the key** — this would make all encrypted data inaccessible
2. Rotate the key material (automatic rotation creates new backing key)
3. Review key policy for unauthorized grants
4. Check CloudTrail for `kms:CreateGrant` and `kms:Decrypt` calls from unexpected principals

### Unauthorized S3 Access

1. Check S3 access logs in `invoice-docs-{env}-access-logs`
2. Check VPC endpoint policy — should be scoped to `invoice-docs-*` only
3. Verify bucket policy denies non-HTTPS access
4. Verify public access block is fully enabled
5. Check IAM roles for overly permissive S3 policies

## Compliance Considerations

### Data Retention

| Requirement | Implementation |
|---|---|
| 10-year document retention | S3 lifecycle expires at 3650 days (10 years) |
| Immutable storage (Prod) | S3 Object Lock GOVERNANCE mode, 3650-day retention |
| Audit trail | S3 access logs, VPC Flow Logs, CloudWatch Logs, Aurora audit logging |

### Encryption

| Requirement | Implementation |
|---|---|
| Encryption at rest | KMS (AES-256) for all services |
| Encryption in transit | TLS/SSL enforced on all paths |
| Key rotation | Annual automatic rotation via KMS |
| Key deletion protection | Explicit deny for non-root principals |

### Access Control

| Requirement | Implementation |
|---|---|
| Least privilege | Scoped IAM policies per workload |
| No public access | Private subnets, S3 public access blocks |
| Credential management | Secrets Manager with managed rotation |
| Network segmentation | Separate app and data subnets, security group micro-segmentation |
