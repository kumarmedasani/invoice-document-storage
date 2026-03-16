# Operations Runbook

## 1. Query Documents by Account and Date Range

### Steps

1. Fetch Aurora credentials:
   ```bash
   SECRET_ARN="<aurora-master-secret-arn>"
   SECRET=$(aws secretsmanager get-secret-value \
     --secret-id "$SECRET_ARN" \
     --query SecretString --output text)
   DB_HOST=$(echo $SECRET | jq -r '.host')
   DB_USER=$(echo $SECRET | jq -r '.username')
   DB_PASS=$(echo $SECRET | jq -r '.password')
   ```

2. Connect and query:
   ```bash
   PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
     -c "SET search_path TO invoice_docs;" \
     -c "
   SELECT d.id, d.s3_key, d.received_date, id.invoice_number
   FROM invoice_docs.documents d
   LEFT JOIN invoice_docs.invoice_details id ON id.document_id = d.id
   WHERE d.account_id = '<account>'
     AND d.received_date BETWEEN '<start_date>' AND '<end_date>'
   ORDER BY d.received_date DESC;
   "
   ```

## 2. Retrieve a Document from Glacier Flexible Retrieval

### Steps

1. Check current storage class:
   ```bash
   aws s3api head-object \
     --bucket invoice-docs-<env> \
     --key "<source>/<year>/<month>/<account>/<uuid>.pdf" \
     --query '{StorageClass: StorageClass, Restore: Restore}'
   ```

2. If `StorageClass` is `GLACIER`, initiate restore:
   ```bash
   aws s3api restore-object \
     --bucket invoice-docs-<env> \
     --key "<source>/<year>/<month>/<account>/<uuid>.pdf" \
     --restore-request '{"Days": 7, "GlacierJobParameters": {"Tier": "Standard"}}'
   ```

3. Poll restore status (Standard tier: 3-5 hours):
   ```bash
   aws s3api head-object \
     --bucket invoice-docs-<env> \
     --key "<source>/<year>/<month>/<account>/<uuid>.pdf" \
     --query 'Restore'
   ```
   Wait until output shows `ongoing-request="false"`.

4. Download the file:
   ```bash
   aws s3 cp \
     "s3://invoice-docs-<env>/<source>/<year>/<month>/<account>/<uuid>.pdf" \
     ./retrieved-document.pdf
   ```

## 3. Retrieve a Document from Glacier Deep Archive

### Steps

Same flow as Glacier Flexible Retrieval, but with longer restore times:

1. Check storage class (will show `DEEP_ARCHIVE`).

2. Initiate restore — choose tier based on urgency:
   - **Standard**: ~12 hours
   - **Bulk** (recommended for non-urgent): ~48 hours, lower cost
   ```bash
   aws s3api restore-object \
     --bucket invoice-docs-<env> \
     --key "<key>" \
     --restore-request '{"Days": 7, "GlacierJobParameters": {"Tier": "Bulk"}}'
   ```

3. Poll restore status periodically.

4. Download once `ongoing-request="false"`.

## 4. Check Aurora Backup Status and Initiate PITR Restore

### Check Available Restore Window

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier invoice-aurora-<env> \
  --query 'DBClusters[0].{
    LatestRestorableTime: LatestRestorableTime,
    EarliestRestorableTime: EarliestRestorableTime,
    BackupRetentionPeriod: BackupRetentionPeriod
  }'
```

### Initiate PITR Restore

1. Create restored cluster:
   ```bash
   aws rds restore-db-cluster-to-point-in-time \
     --source-db-cluster-identifier invoice-aurora-<env> \
     --db-cluster-identifier invoice-aurora-<env>-restored \
     --restore-to-time "2024-03-15T10:30:00Z" \
     --vpc-security-group-ids <sg-aurora-id> \
     --db-subnet-group-name invoice-aurora-<env> \
     --kms-key-id <kms-key-arn>
   ```

2. Create instance in restored cluster:
   ```bash
   aws rds create-db-instance \
     --db-instance-identifier invoice-aurora-<env>-restored-0 \
     --db-cluster-identifier invoice-aurora-<env>-restored \
     --engine aurora-postgresql \
     --db-instance-class <instance-class>
   ```

3. Post-restore steps:
   - Update Secrets Manager with new cluster endpoint
   - Update RDS Proxy target (if using proxy)
   - Verify data integrity with validation queries
   - Update application configuration if needed

**RPO**: ~1 hour (Aurora continuous backup)
**RTO**: ~4 hours for full restore and validation

## 5. Rotate Aurora Master Secret Manually (Incident Response)

### Steps

1. Trigger immediate rotation:
   ```bash
   aws secretsmanager rotate-secret \
     --secret-id <master-secret-arn> \
     --rotate-immediately
   ```

2. Verify rotation completed:
   ```bash
   aws secretsmanager describe-secret \
     --secret-id <master-secret-arn> \
     --query '{
       RotationEnabled: RotationEnabled,
       LastRotatedDate: LastRotatedDate,
       VersionIdsToStages: VersionIdsToStages
     }'
   ```

3. Verify connectivity with new credentials:
   ```bash
   NEW_SECRET=$(aws secretsmanager get-secret-value \
     --secret-id <master-secret-arn> \
     --query SecretString --output text)
   PGPASSWORD=$(echo $NEW_SECRET | jq -r '.password') \
     psql -h $(echo $NEW_SECRET | jq -r '.host') \
          -U $(echo $NEW_SECRET | jq -r '.username') \
          -d postgres -c "SELECT 1"
   ```

**Important**: Application services must not cache credentials for more than
5 minutes. If using RDS Proxy, it handles credential rotation automatically.

## 6. Troubleshooting: Connection Failures

### Diagnostic Steps

1. **Check RDS Proxy health** (Stage/Prod):
   ```bash
   aws rds describe-db-proxy-targets \
     --db-proxy-name invoice-proxy-<env> \
     --query 'Targets[*].{State: TargetHealth.State, Description: TargetHealth.Description}'
   ```

2. **Check security group rules** (port 5432):
   ```bash
   aws ec2 describe-security-groups \
     --group-ids <sg-aurora-id> \
     --query 'SecurityGroups[0].IpPermissions'
   ```

3. **Check VPC endpoint status**:
   ```bash
   aws ec2 describe-vpc-endpoints \
     --filters "Name=vpc-id,Values=<vpc-id>" \
     --query 'VpcEndpoints[*].{Service: ServiceName, State: State}'
   ```

4. **Check IAM role has Secrets Manager access**:
   ```bash
   aws iam simulate-principal-policy \
     --policy-source-arn <role-arn> \
     --action-names secretsmanager:GetSecretValue \
     --resource-arns <secret-arn>
   ```

5. **Verify SSL mode**: connections must use `sslmode=require`:
   ```bash
   PGPASSWORD="$DB_PASS" psql \
     "host=$DB_HOST user=$DB_USER dbname=postgres sslmode=require" \
     -c "SELECT 1"
   ```

## 7. Troubleshooting: KMS Encryption Errors

### Common Errors

| Error | Cause | Resolution |
|---|---|---|
| `KMSDisabledException` | KMS key is disabled | Re-enable: `aws kms enable-key --key-id <key-id>` |
| `AccessDeniedException` | IAM role missing kms:Decrypt | Check IAM policy, verify kms:Decrypt on the key ARN |
| `KMSInvalidStateException` | Key pending deletion | Cancel: `aws kms cancel-key-deletion --key-id <key-id>` |

### Diagnostic Steps

1. Check key state:
   ```bash
   aws kms describe-key --key-id <key-id> \
     --query 'KeyMetadata.{State: KeyState, Enabled: Enabled}'
   ```

2. Check key policy grants:
   ```bash
   aws kms get-key-policy --key-id <key-id> --policy-name default \
     --query Policy --output text | jq .
   ```

3. Test encryption with the key:
   ```bash
   aws kms generate-data-key --key-id <key-id> --key-spec AES_256
   ```

## 8. Troubleshooting: S3 Access Denied

### Diagnostic Steps

1. **Verify bucket policy** (HTTPS enforcement may block HTTP clients):
   ```bash
   aws s3api get-bucket-policy --bucket invoice-docs-<env> \
     --query Policy --output text | jq .
   ```

2. **Verify IAM role permissions**:
   ```bash
   aws iam simulate-principal-policy \
     --policy-source-arn <role-arn> \
     --action-names s3:PutObject \
     --resource-arns "arn:aws:s3:::invoice-docs-<env>/*"
   ```

3. **Verify KMS key policy** allows `kms:GenerateDataKey`:
   ```bash
   aws kms get-key-policy --key-id <key-id> --policy-name default \
     --query Policy --output text | jq '.Statement[] | select(.Sid == "ServicePrincipalUsage")'
   ```

4. **Check S3 Block Public Access settings**:
   ```bash
   aws s3api get-public-access-block --bucket invoice-docs-<env>
   ```
   All four settings should be `true`. If a client is getting access denied,
   ensure it is using proper IAM credentials (not trying public access).

5. **Check VPC endpoint policy** (if accessing from within VPC):
   ```bash
   aws ec2 describe-vpc-endpoints \
     --filters "Name=service-name,Values=com.amazonaws.*.s3" \
     --query 'VpcEndpoints[0].PolicyDocument'
   ```
   The endpoint policy restricts access to `invoice-docs-*` buckets only.
