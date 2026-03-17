# Operations Runbook

This document contains step-by-step operational procedures for the Invoice Document Storage platform. Each runbook is self-contained and can be followed independently.

## Table of Contents

- [1. Query Documents by Account and Date Range](#1-query-documents-by-account-and-date-range)
- [2. Retrieve a Document from Glacier Flexible Retrieval](#2-retrieve-a-document-from-glacier-flexible-retrieval)
- [3. Retrieve a Document from Glacier Deep Archive](#3-retrieve-a-document-from-glacier-deep-archive)
- [4. Aurora Point-in-Time Restore (PITR)](#4-aurora-point-in-time-restore-pitr)
- [5. Rotate Aurora Master Secret (Incident Response)](#5-rotate-aurora-master-secret-incident-response)
- [6. Troubleshooting: Connection Failures](#6-troubleshooting-connection-failures)
- [7. Troubleshooting: KMS Encryption Errors](#7-troubleshooting-kms-encryption-errors)
- [8. Troubleshooting: S3 Access Denied](#8-troubleshooting-s3-access-denied)
- [9. Managing Database Partitions](#9-managing-database-partitions)
- [10. Viewing CloudWatch Dashboard and Alarms](#10-viewing-cloudwatch-dashboard-and-alarms)
- [11. Investigating VPC Flow Logs](#11-investigating-vpc-flow-logs)
- [12. S3 Object Lock Operations](#12-s3-object-lock-operations)
- [13. Troubleshooting: SFTP Connectivity](#13-troubleshooting-sftp-connectivity)
- [14. Troubleshooting: Landing Zone Processing](#14-troubleshooting-landing-zone-processing)
- [15. Troubleshooting: Splunk Log Streaming](#15-troubleshooting-splunk-log-streaming)

## Common Setup: Retrieve Aurora Credentials

Most runbooks require Aurora credentials. Use this pattern to retrieve them:

```bash
ENV="qa"  # Change to stage or prod as needed

# Get the secret ARN from Terraform output (or look it up)
cd terraform/envs/$ENV
SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)

# Or look up directly
SECRET_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' \
  --output text)

# Retrieve credentials
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text)

DB_HOST=$(echo "$SECRET" | jq -r '.host')
DB_USER=$(echo "$SECRET" | jq -r '.username')
DB_PASS=$(echo "$SECRET" | jq -r '.password')
DB_PORT=$(echo "$SECRET" | jq -r '.port // 5432')
```

**For Stage/Prod with RDS Proxy**, use the proxy endpoint instead:

```bash
# Get proxy endpoint
PROXY_ENDPOINT=$(aws rds describe-db-proxies \
  --query "DBProxies[?DBProxyName=='invoice-proxy-$ENV'].Endpoint" \
  --output text)

# Use proxy endpoint as host
DB_HOST="$PROXY_ENDPOINT"
```

---

## 1. Query Documents by Account and Date Range

**When to use:** A customer requests copies of their invoices, or you need to look up documents for audit purposes.

### Steps

1. Retrieve Aurora credentials (see [Common Setup](#common-setup-retrieve-aurora-credentials)).

2. Connect and query:

```bash
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres <<'SQL'
SET search_path TO invoice_docs;

-- Query invoices for a specific account and date range
SELECT
    d.id AS document_id,
    d.s3_bucket,
    d.s3_key,
    d.received_date,
    d.source_system,
    d.status,
    id.invoice_number,
    id.invoice_date,
    id.amount_cents / 100.0 AS amount_usd,
    id.currency_code
FROM documents d
LEFT JOIN invoice_details id ON id.document_id = d.id
WHERE d.account_id = 'ACC-00123456'
  AND d.received_date BETWEEN '2023-01-01' AND '2023-12-31'
  AND d.status = 'active'
ORDER BY d.received_date DESC;
SQL
```

3. Download the PDF(s) from S3:

```bash
# Single document
aws s3 cp "s3://invoice-docs-$ENV/<s3_key>" ./document.pdf

# All documents for an account (prefix search)
aws s3 cp "s3://invoice-docs-$ENV/billing_system/2023/" ./downloads/ \
  --recursive --exclude "*" --include "*ACC-00123456*"
```

### Useful Variations

```sql
-- Count documents per source system
SELECT source_system, COUNT(*) FROM documents
GROUP BY source_system ORDER BY count DESC;

-- Find documents by invoice number
SELECT d.*, id.invoice_number, id.amount_cents
FROM documents d JOIN invoice_details id ON id.document_id = d.id
WHERE id.invoice_number = 'INV-2023-00456';

-- Find collection letters for an account
SELECT d.*, cl.letter_type, cl.balance_due_cents / 100.0 AS balance_usd
FROM documents d JOIN collection_letter_details cl ON cl.document_id = d.id
WHERE d.account_id = 'ACC-00123456' AND d.document_kind = 'collection_letter'
ORDER BY cl.letter_date DESC;

-- Check partition sizes
SELECT
    schemaname || '.' || tablename AS partition,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS size,
    n_live_tup AS row_count
FROM pg_stat_user_tables
WHERE schemaname = 'invoice_docs' AND tablename LIKE 'documents_y%'
ORDER BY tablename;
```

---

## 2. Retrieve a Document from Glacier Flexible Retrieval

**When to use:** A document is 2-7 years old and has been transitioned to Glacier Flexible Retrieval (day 731-2555).

### Steps

1. Check current storage class:

```bash
aws s3api head-object \
  --bucket "invoice-docs-$ENV" \
  --key "<source>/<year>/<month>/<account>/<uuid>.pdf" \
  --query '{StorageClass: StorageClass, Restore: Restore}'
```

If `StorageClass` is `GLACIER`, proceed with the restore.

2. Initiate restore (choose tier based on urgency):

| Tier | Restore Time | Cost |
|---|---|---|
| Expedited | 1-5 minutes | $$$$ (not available for all objects) |
| Standard | 3-5 hours | $$ |
| Bulk | 5-12 hours | $ |

```bash
# Standard tier (recommended)
aws s3api restore-object \
  --bucket "invoice-docs-$ENV" \
  --key "<source>/<year>/<month>/<account>/<uuid>.pdf" \
  --restore-request '{"Days": 7, "GlacierJobParameters": {"Tier": "Standard"}}'
```

3. Poll restore status (every 30 minutes for Standard):

```bash
aws s3api head-object \
  --bucket "invoice-docs-$ENV" \
  --key "<source>/<year>/<month>/<account>/<uuid>.pdf" \
  --query 'Restore'
```

- `ongoing-request="true"` — Still restoring
- `ongoing-request="false", expiry-date="..."` — Ready to download

4. Download the restored file:

```bash
aws s3 cp \
  "s3://invoice-docs-$ENV/<source>/<year>/<month>/<account>/<uuid>.pdf" \
  ./retrieved-document.pdf
```

**Note:** The restored copy is available for `Days` days (7 in the example above). After that, the object returns to Glacier. Download promptly.

---

## 3. Retrieve a Document from Glacier Deep Archive

**When to use:** A document is 7-10 years old and has been transitioned to Glacier Deep Archive (day 2556-3649).

### Steps

Same flow as Glacier Flexible Retrieval, but with longer restore times:

| Tier | Restore Time | Cost |
|---|---|---|
| Standard | ~12 hours | $$ |
| Bulk | ~48 hours | $ (recommended for non-urgent) |

```bash
# Bulk tier (recommended for cost savings)
aws s3api restore-object \
  --bucket "invoice-docs-$ENV" \
  --key "<key>" \
  --restore-request '{"Days": 7, "GlacierJobParameters": {"Tier": "Bulk"}}'
```

Poll every 4 hours for Standard, every 12 hours for Bulk.

### Batch Restore

To restore multiple documents at once (e.g., all documents for an account across years):

```bash
# List all objects under a prefix
aws s3api list-objects-v2 \
  --bucket "invoice-docs-$ENV" \
  --prefix "billing_system/2018/" \
  --query 'Contents[?StorageClass==`DEEP_ARCHIVE`].Key' \
  --output text | tr '\t' '\n' | while read key; do
    echo "Restoring: $key"
    aws s3api restore-object \
      --bucket "invoice-docs-$ENV" \
      --key "$key" \
      --restore-request '{"Days": 7, "GlacierJobParameters": {"Tier": "Bulk"}}' \
      2>/dev/null || echo "  (already restoring or not in Deep Archive)"
done
```

---

## 4. Aurora Point-in-Time Restore (PITR)

**When to use:** Database corruption, accidental data deletion, or need to recover to a specific point in time.

### Check Available Restore Window

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].{
    LatestRestorableTime: LatestRestorableTime,
    EarliestRestorableTime: EarliestRestorableTime,
    BackupRetentionPeriod: BackupRetentionPeriod,
    Status: Status
  }'
```

### Perform PITR Restore

1. **Create restored cluster** (this creates a new cluster alongside the existing one):

```bash
# Get current cluster's config for reference
KMS_KEY_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].KmsKeyId' --output text)

SG_ID=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)

SUBNET_GROUP=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].DBSubnetGroup' --output text)

# Restore to a specific point in time
aws rds restore-db-cluster-to-point-in-time \
  --source-db-cluster-identifier "invoice-aurora-$ENV" \
  --db-cluster-identifier "invoice-aurora-$ENV-restored" \
  --restore-to-time "2024-03-15T10:30:00Z" \
  --vpc-security-group-ids "$SG_ID" \
  --db-subnet-group-name "$SUBNET_GROUP" \
  --kms-key-id "$KMS_KEY_ARN"

# Wait for cluster to be available
aws rds wait db-cluster-available \
  --db-cluster-identifier "invoice-aurora-$ENV-restored"
```

2. **Create instance in restored cluster:**

```bash
INSTANCE_CLASS=$(aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=invoice-aurora-$ENV" \
  --query 'DBInstances[0].DBInstanceClass' --output text)

aws rds create-db-instance \
  --db-instance-identifier "invoice-aurora-$ENV-restored-0" \
  --db-cluster-identifier "invoice-aurora-$ENV-restored" \
  --engine aurora-postgresql \
  --db-instance-class "$INSTANCE_CLASS"

# Wait for instance
aws rds wait db-instance-available \
  --db-instance-identifier "invoice-aurora-$ENV-restored-0"
```

3. **Validate the restored data:**

```bash
# Get the new cluster endpoint
RESTORED_HOST=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV-restored" \
  --query 'DBClusters[0].Endpoint' --output text)

# Connect and run validation queries
PGPASSWORD="$DB_PASS" psql -h "$RESTORED_HOST" -U "$DB_USER" -d postgres \
  -c "SELECT COUNT(*) FROM invoice_docs.documents;"
```

4. **Switch over** (if the restored data looks correct):
   - Update Secrets Manager with the new cluster endpoint
   - Update RDS Proxy target to point to the new cluster (if using proxy)
   - Update application configuration
   - Delete the old cluster (after confirming the switch)

**Recovery metrics:**
- **RPO:** ~5 minutes (Aurora continuous backup)
- **RTO:** ~4 hours (restore + instance creation + validation + switchover)

---

## 5. Rotate Aurora Master Secret (Incident Response)

**When to use:** Suspected credential leak, security incident, or scheduled rotation override.

### Steps

1. **Trigger immediate rotation:**

```bash
SECRET_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)

aws secretsmanager rotate-secret \
  --secret-id "$SECRET_ARN" \
  --rotate-immediately
```

2. **Monitor rotation status:**

```bash
# Wait for rotation to complete (typically 30-60 seconds)
watch -n 5 'aws secretsmanager describe-secret \
  --secret-id "'$SECRET_ARN'" \
  --query "{Status: RotationEnabled, LastRotated: LastRotatedDate, Versions: VersionIdsToStages}"'
```

3. **Verify connectivity with new credentials:**

```bash
NEW_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text)

PGPASSWORD=$(echo "$NEW_SECRET" | jq -r '.password') \
  psql -h "$(echo "$NEW_SECRET" | jq -r '.host')" \
       -U "$(echo "$NEW_SECRET" | jq -r '.username')" \
       -d postgres -c "SELECT 1 AS connection_test;"
```

4. **Verify RDS Proxy health** (Stage/Prod):

```bash
aws rds describe-db-proxy-targets \
  --db-proxy-name "invoice-proxy-$ENV" \
  --query 'Targets[*].{State: TargetHealth.State, Description: TargetHealth.Description}'
```

**Important notes:**
- Application services must not cache credentials for more than 5 minutes
- RDS Proxy handles credential rotation automatically — no application restart needed
- QA (no proxy) may require application restart if credentials are cached

---

## 6. Troubleshooting: Connection Failures

### Diagnostic Checklist

1. **Check Aurora cluster status:**

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].{Status: Status, Endpoint: Endpoint, ReaderEndpoint: ReaderEndpoint}'
```

2. **Check RDS Proxy health** (Stage/Prod):

```bash
aws rds describe-db-proxy-targets \
  --db-proxy-name "invoice-proxy-$ENV" \
  --query 'Targets[*].{State: TargetHealth.State, Reason: TargetHealth.Reason, Description: TargetHealth.Description}'
```

Expected state: `AVAILABLE`. If `UNAVAILABLE`, check Aurora cluster status.

3. **Check security group rules** (verify port 5432 is open from app tier):

```bash
SG_AURORA=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)

aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$SG_AURORA" \
  --query 'SecurityGroupRules[*].{Direction: IsEgress, Port: FromPort, Source: ReferencedGroupInfo.GroupId, Description: Description}'
```

4. **Check VPC endpoint status:**

```bash
VPC_ID=$(aws rds describe-db-clusters \
  --db-cluster-identifier "invoice-aurora-$ENV" \
  --query 'DBClusters[0].DBSubnetGroup.Subnets[0].SubnetIdentifier' --output text \
  | xargs aws ec2 describe-subnets --subnet-ids --query 'Subnets[0].VpcId' --output text)

aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[*].{Service: ServiceName, State: State}'
```

All endpoints should be in `available` state.

5. **Test SSL connectivity directly:**

```bash
PGPASSWORD="$DB_PASS" psql \
  "host=$DB_HOST user=$DB_USER dbname=postgres sslmode=require port=$DB_PORT" \
  -c "SELECT 1"
```

If this fails with `SSL error`, the `rds.force_ssl` parameter may have been modified. Check the parameter group.

6. **Check IAM role has Secrets Manager access** (for applications that fetch credentials):

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "<role-arn>" \
  --action-names secretsmanager:GetSecretValue \
  --resource-arns "$SECRET_ARN"
```

---

## 7. Troubleshooting: KMS Encryption Errors

### Common Errors and Resolutions

| Error | Cause | Resolution |
|---|---|---|
| `KMSDisabledException` | KMS key is disabled | `aws kms enable-key --key-id <key-id>` |
| `AccessDeniedException` | IAM role missing kms:Decrypt | Verify IAM policy grants `kms:Decrypt` on the key ARN |
| `KMSInvalidStateException` | Key pending deletion | `aws kms cancel-key-deletion --key-id <key-id>` |
| `ThrottlingException` | Too many KMS API calls | Verify `bucket_key_enabled = true` on S3 bucket |
| `KMSKeyNotAccessibleException` | Key policy doesn't allow access | Check key policy (root admin + service grants) |

### Diagnostic Steps

```bash
# Get key ID from alias
KEY_ID=$(aws kms describe-key \
  --key-id "alias/invoice-$ENV" \
  --query 'KeyMetadata.KeyId' --output text)

# 1. Check key state
aws kms describe-key --key-id "$KEY_ID" \
  --query 'KeyMetadata.{State: KeyState, Enabled: Enabled, RotationEnabled: KeyRotationStatus}'

# 2. Check key policy
aws kms get-key-policy --key-id "$KEY_ID" --policy-name default \
  --query Policy --output text | jq .

# 3. Test encryption capability
aws kms generate-data-key --key-id "$KEY_ID" --key-spec AES_256 \
  --query '{KeyId: KeyId}' 2>&1

# 4. Check S3 bucket key status (should reduce throttling by ~99%)
aws s3api get-bucket-encryption \
  --bucket "invoice-docs-$ENV" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled'
```

---

## 8. Troubleshooting: S3 Access Denied

### Diagnostic Steps

```bash
BUCKET="invoice-docs-$ENV"

# 1. Verify bucket policy (HTTPS enforcement)
aws s3api get-bucket-policy --bucket "$BUCKET" \
  --query Policy --output text | jq .

# 2. Check public access block settings (all should be true)
aws s3api get-public-access-block --bucket "$BUCKET"

# 3. Simulate IAM permissions for a specific role
aws iam simulate-principal-policy \
  --policy-source-arn "<role-arn>" \
  --action-names s3:PutObject s3:GetObject s3:ListBucket \
  --resource-arns "arn:aws:s3:::$BUCKET" "arn:aws:s3:::$BUCKET/*"

# 4. Check VPC endpoint policy (restricts to invoice-docs-* buckets)
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.*.s3" \
  --query 'VpcEndpoints[0].PolicyDocument' | jq .

# 5. Verify KMS permissions (required for SSE-KMS encrypted objects)
aws iam simulate-principal-policy \
  --policy-source-arn "<role-arn>" \
  --action-names kms:GenerateDataKey kms:Decrypt \
  --resource-arns "$(aws kms describe-key --key-id alias/invoice-$ENV --query KeyMetadata.Arn --output text)"
```

### Common Causes

| Symptom | Likely Cause | Fix |
|---|---|---|
| All S3 calls fail with 403 | HTTPS enforcement + HTTP client | Ensure client uses HTTPS |
| PutObject fails, GetObject works | Missing `kms:GenerateDataKey` | Add to IAM policy |
| GetObject fails for old objects | Missing `kms:Decrypt` | Add to IAM policy |
| Access works outside VPC, fails inside | VPC endpoint policy too restrictive | Check endpoint policy allows the bucket |
| ListBucket fails | Missing `s3:ListBucket` on bucket ARN (not object ARN) | Fix IAM policy resource |

---

## 9. Managing Database Partitions

### Check Current Partitions

```bash
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres <<'SQL'
SELECT
    c.relname AS partition_name,
    pg_get_expr(c.relpartbound, c.oid) AS partition_range,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    s.n_live_tup AS row_estimate
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relispartition
  AND n.nspname = 'invoice_docs'
  AND c.relname LIKE 'documents_%'
ORDER BY c.relname;
SQL
```

### Create a New Yearly Partition

```bash
# Create partition for year 2028
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
  -c "SELECT invoice_docs.create_yearly_partition(2028);"
```

### Verify Partition Auto-Creation

The schema deployment runs `create_yearly_partition(EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER + 1)` automatically. To verify:

```bash
NEXT_YEAR=$(($(date +%Y) + 1))
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
  -c "SELECT invoice_docs.create_yearly_partition($NEXT_YEAR);"
# Should return: "Partition documents_yNNNN already exists"
```

---

## 10. Viewing CloudWatch Dashboard and Alarms

### Open Dashboard

```bash
# Get dashboard URL
echo "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=invoice-$ENV"
```

### Check All Alarm States

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "aurora-" \
  --query 'MetricAlarms[*].{Name: AlarmName, State: StateValue, Reason: StateReason}' \
  --output table

aws cloudwatch describe-alarms \
  --alarm-name-prefix "s3-" \
  --query 'MetricAlarms[*].{Name: AlarmName, State: StateValue}' \
  --output table

aws cloudwatch describe-alarms \
  --alarm-name-prefix "kms-" \
  --query 'MetricAlarms[*].{Name: AlarmName, State: StateValue}' \
  --output table
```

### Query Application Logs

```bash
# Search for errors in the last 24 hours
aws logs filter-log-events \
  --log-group-name "/invoice/application/$ENV" \
  --filter-pattern '{ $.level = "ERROR" }' \
  --start-time $(date -d '24 hours ago' +%s000) \
  --query 'events[*].message' --output text
```

---

## 11. Investigating VPC Flow Logs

### Query Rejected Traffic

```bash
# Find rejected connections in the last hour
aws logs filter-log-events \
  --log-group-name "/aws/vpc/invoice-vpc-$ENV/flow-logs" \
  --filter-pattern "REJECT" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --query 'events[*].message' --output text | head -20
```

### Query Traffic to Aurora (Port 5432)

```bash
aws logs filter-log-events \
  --log-group-name "/aws/vpc/invoice-vpc-$ENV/flow-logs" \
  --filter-pattern '"5432"' \
  --start-time $(date -d '1 hour ago' +%s000) \
  --query 'events[*].message' --output text | head -20
```

---

## 12. S3 Object Lock Operations

**Applies to Prod only** (Object Lock not enabled in QA/Stage).

### Check Object Lock Status

```bash
aws s3api get-object-lock-configuration --bucket invoice-docs-prod
```

### Check Retention on a Specific Object

```bash
aws s3api head-object \
  --bucket invoice-docs-prod \
  --key "<s3_key>" \
  --query '{ObjectLockMode: ObjectLockMode, RetainUntilDate: ObjectLockRetainUntilDate}'
```

### Override Object Lock (Emergency)

GOVERNANCE mode allows override by principals with `s3:BypassGovernanceRetention` permission:

```bash
aws s3api delete-object \
  --bucket invoice-docs-prod \
  --key "<s3_key>" \
  --bypass-governance-retention
```

**Warning:** This should only be done in emergency situations with documented approval. All Object Lock bypass actions are logged in the S3 access logs bucket.

---

## 13. Troubleshooting: SFTP Connectivity

**When to use:** Vendors report they cannot connect to the SFTP server or upload files.

### Diagnostic Steps

1. **Check Transfer Family server status:**

```bash
# Get server ID from Terraform output
cd terraform/envs/$ENV
SERVER_ID=$(terraform output -raw sftp_server_id 2>/dev/null || \
  aws transfer list-servers \
    --query "Servers[?Tags[?Key=='Name' && contains(Value, '$ENV')]].ServerId" \
    --output text)

aws transfer describe-server --server-id "$SERVER_ID" \
  --query '{State: State, Endpoint: EndpointDetails, Protocol: Protocols}'
```

Expected state: `ONLINE`. If `OFFLINE` or `START_FAILED`, check CloudWatch logs.

2. **Verify SFTP user exists:**

```bash
aws transfer list-users --server-id "$SERVER_ID" \
  --query 'Users[*].{UserName: UserName, Role: Role}'
```

3. **Check SFTP logging role:**

```bash
aws transfer describe-server --server-id "$SERVER_ID" \
  --query 'Server.LoggingRole'
```

If empty, the server cannot write logs. Verify the IAM role exists.

4. **Check landing bucket permissions:**

```bash
# Verify the SFTP user role can write to the landing bucket
SFTP_ROLE_ARN=$(aws transfer list-users --server-id "$SERVER_ID" \
  --query 'Users[0].Role' --output text)

aws iam simulate-principal-policy \
  --policy-source-arn "$SFTP_ROLE_ARN" \
  --action-names s3:PutObject \
  --resource-arns "arn:aws:s3:::invoice-landing-$ENV/*"
```

5. **Check Transfer Family structured logs:**

```bash
aws logs filter-log-events \
  --log-group-name "/invoice/application/$ENV" \
  --filter-pattern '"transfer.amazonaws.com"' \
  --start-time $(date -d '1 hour ago' +%s000) \
  --query 'events[*].message' --output text
```

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Connection refused | Server is OFFLINE | `aws transfer start-server --server-id $SERVER_ID` |
| Authentication failed | No SFTP user configured | Create user with `aws transfer create-user` |
| Upload fails with 403 | SFTP user role missing S3 permissions | Check IAM role policy |
| Upload succeeds but Lambda not triggered | SNS notification not configured on landing bucket | Verify S3 event notification configuration |

---

## 14. Troubleshooting: Landing Zone Processing

**When to use:** Files are uploaded to the landing zone but not appearing in the documents bucket, or Lambda is not processing them.

### Diagnostic Steps

1. **Check landing bucket for unprocessed files:**

```bash
aws s3 ls "s3://invoice-landing-$ENV/" --recursive --human-readable
```

Files older than a few minutes indicate processing failures.

2. **Check S3 event notification configuration:**

```bash
aws s3api get-bucket-notification-configuration \
  --bucket "invoice-landing-$ENV" \
  --query '{SNS: TopicConfigurations}'
```

Should show an `s3:ObjectCreated:*` event targeting the SNS topic.

3. **Check SNS topic subscriptions:**

```bash
SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)
aws sns list-subscriptions-by-topic --topic-arn "$SNS_TOPIC_ARN" \
  --query 'Subscriptions[*].{Protocol: Protocol, Endpoint: Endpoint, Status: SubscriptionArn}'
```

4. **Check Lambda invocation errors:**

```bash
# Check for Lambda errors in CloudWatch Logs
aws logs filter-log-events \
  --log-group-name "/invoice/application/$ENV" \
  --filter-pattern '{ $.level = "ERROR" }' \
  --start-time $(date -d '1 hour ago' +%s000) \
  --query 'events[*].message' --output text
```

5. **Check Lambda function metrics:**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions "Name=FunctionName,Value=invoice-ingestion-$ENV" \
  --start-time "$(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Sum
```

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Files stuck in landing bucket | Lambda not triggered | Check SNS topic and S3 event notification |
| Lambda timeout | ZIP file too large for Lambda /tmp | Increase Lambda memory/timeout or split ZIP |
| Lambda AccessDenied on landing bucket | Missing `s3:GetObject` or `s3:DeleteObject` on landing bucket | Check Lambda IAM policy |
| Lambda AccessDenied on documents bucket | Missing `s3:PutObject` on documents bucket | Check Lambda IAM policy |
| Duplicate processing | S3 event delivered twice (at-least-once) | Implement idempotency via `s3_key` unique constraint in Aurora |

---

## 15. Troubleshooting: Splunk Log Streaming

**When to use:** Logs are not appearing in Splunk, or there are gaps in log data.

### Diagnostic Steps

1. **Check Firehose delivery stream status:**

```bash
aws firehose describe-delivery-stream \
  --delivery-stream-name "invoice-logs-to-splunk-$ENV" \
  --query '{Status: DeliveryStreamDescription.DeliveryStreamStatus, LastUpdate: DeliveryStreamDescription.LastUpdateTimestamp}'
```

Expected status: `ACTIVE`.

2. **Check subscription filters:**

```bash
for LOG_GROUP in "/invoice/application/$ENV" "/invoice/aurora/$ENV" "/invoice/migration/$ENV" "/aws/vpc/invoice-vpc-$ENV/flow-logs"; do
  echo "=== $LOG_GROUP ==="
  aws logs describe-subscription-filters \
    --log-group-name "$LOG_GROUP" \
    --query 'subscriptionFilters[*].{Name: filterName, Destination: destinationArn}' 2>/dev/null || echo "  No subscription filter"
done
```

3. **Check Firehose error logs:**

```bash
aws logs filter-log-events \
  --log-group-name "/invoice/application/$ENV" \
  --log-stream-name-prefix "firehose-splunk-errors" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --query 'events[*].message' --output text
```

4. **Check Firehose metrics (failed deliveries):**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToSplunk.DataFreshness \
  --dimensions "Name=DeliveryStreamName,Value=invoice-logs-to-splunk-$ENV" \
  --start-time "$(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Average
```

5. **Check S3 backup bucket for failed deliveries:**

```bash
aws s3 ls "s3://invoice-firehose-backup-$ENV/" --recursive --human-readable
```

Files here indicate Firehose could not deliver to Splunk HEC. Check HEC endpoint availability and token validity.

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| No logs in Splunk | Subscription filters missing | Verify filters exist on all log groups |
| Logs delayed (> 5 min) | Firehose buffering | Check `buffering_interval` setting |
| Failed deliveries in S3 backup | Splunk HEC endpoint down | Verify HEC endpoint URL and connectivity |
| 403 from Splunk HEC | Invalid or expired HEC token | Rotate token in Splunk, update `splunk_hec_token` tfvar |
| Logs in wrong Splunk index | HEC token misconfigured | Verify token-to-index mapping in Splunk admin |
| Partial log groups missing | Subscription filter limit (2 per log group) | Check if another subscription filter exists |
