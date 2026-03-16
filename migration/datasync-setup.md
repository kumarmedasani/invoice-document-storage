# DataSync Setup Guide

This guide covers migrating document files (PDFs) from a legacy Windows file share
to the S3 document storage bucket using AWS DataSync.

## Prerequisites

- AWS CLI v2 installed and configured
- Network connectivity between the DataSync agent and the Windows file share
- IAM role `invoice-migration-{env}` created (via Terraform)
- S3 bucket `invoice-docs-{env}` created (via Terraform)
- Legacy file share credentials stored in Secrets Manager

## 1. Deploy DataSync Agent

### Option A: EC2-based Agent (recommended for VPC access)

1. Find the latest DataSync AMI:

```bash
aws ssm get-parameter \
  --name /aws/service/datasync/ami \
  --region us-east-1 \
  --query "Parameter.Value" \
  --output text
```

2. Launch the EC2 instance in the same subnet as the Windows file share
   (or a subnet with connectivity via Direct Connect):

```bash
aws ec2 run-instances \
  --image-id <datasync-ami-id> \
  --instance-type m5.2xlarge \
  --subnet-id <subnet-id> \
  --security-group-ids <sg-id> \
  --key-name <keypair-name> \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=invoice-datasync-agent}]'
```

3. Activate the agent. Get the agent's IP from EC2 console, then:

```bash
aws datasync create-agent \
  --activation-key <key-from-agent-console> \
  --agent-name invoice-datasync-agent-<env> \
  --tags Key=Environment,Value=<env> Key=Project,Value=invoice-doc-storage
```

### Option B: VMware Agent (on-premises)

Follow the [AWS DataSync VMware deployment guide](https://docs.aws.amazon.com/datasync/latest/userguide/deploy-agents.html)
and activate using the same `create-agent` command above.

## 2. Create Source Location (SMB File Share)

```bash
# Fetch credentials from Secrets Manager
SMB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id invoice-fileshare-<env> \
  --query SecretString --output text)

SMB_USER=$(echo $SMB_SECRET | jq -r '.username')
SMB_PASS=$(echo $SMB_SECRET | jq -r '.password')

aws datasync create-location-smb \
  --server-hostname <windows-server-ip> \
  --subdirectory "/invoices" \
  --user "$SMB_USER" \
  --password "$SMB_PASS" \
  --agent-arns <agent-arn> \
  --tags Key=Environment,Value=<env> Key=Project,Value=invoice-doc-storage
```

Repeat for each source system subdirectory if they are stored separately.

## 3. Create Destination Location (S3)

Create one destination per source system to use the correct S3 prefix:

```bash
aws datasync create-location-s3 \
  --s3-bucket-arn arn:aws:s3:::invoice-docs-<env> \
  --subdirectory "/<source_system_name>" \
  --s3-config BucketAccessRoleArn=arn:aws:iam::<account-id>:role/invoice-migration-<env> \
  --s3-storage-class STANDARD \
  --tags Key=Environment,Value=<env> Key=Project,Value=invoice-doc-storage
```

## 4. Create DataSync Task

```bash
aws datasync create-task \
  --source-location-arn <smb-location-arn> \
  --destination-location-arn <s3-location-arn> \
  --name "invoice-migration-<source_system>-<env>" \
  --options '{
    "VerifyMode": "ONLY_FILES_TRANSFERRED",
    "OverwriteMode": "NEVER",
    "Atime": "BEST_EFFORT",
    "Mtime": "PRESERVE",
    "PreserveDeletedFiles": "PRESERVE",
    "PreserveDevices": "NONE",
    "PosixPermissions": "NONE",
    "BytesPerSecond": 12500000,
    "TaskQueueing": "ENABLED",
    "LogLevel": "TRANSFER",
    "TransferMode": "CHANGED",
    "SecurityDescriptorCopyFlags": "NONE",
    "ObjectTags": "NONE"
  }' \
  --includes '[{"FilterType": "SIMPLE_PATTERN", "Value": "*.pdf"}]' \
  --cloud-watch-log-group-arn arn:aws:logs:<region>:<account-id>:log-group:/invoice/migration/<env> \
  --tags Key=Environment,Value=<env> Key=Project,Value=invoice-doc-storage
```

### Bandwidth Configuration

| Environment | Bandwidth Limit | Notes |
|---|---|---|
| QA | 12,500,000 bytes/s (~100 Mbps) | Throttled to avoid impacting production |
| Stage | 12,500,000 bytes/s (~100 Mbps) | Throttled to avoid impacting production |
| Prod | -1 (unlimited) | Run during off-hours maintenance window |

To update bandwidth for Prod (off-hours):

```bash
aws datasync update-task \
  --task-arn <task-arn> \
  --options '{"BytesPerSecond": -1}'
```

## 5. Execute DataSync Task

```bash
# Start task execution
aws datasync start-task-execution \
  --task-arn <task-arn>

# Monitor progress
aws datasync describe-task-execution \
  --task-execution-arn <execution-arn>
```

## 6. Validation After DataSync Completes

### Check DataSync Transfer Summary

```bash
aws datasync describe-task-execution \
  --task-execution-arn <execution-arn> \
  --query '{
    Status: Status,
    FilesTransferred: FilesTransferred,
    BytesTransferred: BytesTransferred,
    FilesVerified: FilesVerified
  }'
```

### Compare File Count: Source vs S3

```bash
# Count objects in S3 for this source system
aws s3api list-objects-v2 \
  --bucket invoice-docs-<env> \
  --prefix "<source_system>/" \
  --query "KeyCount"
```

### CloudWatch Logs Query

Check the DataSync transfer log for errors:

```bash
aws logs filter-log-events \
  --log-group-name "/invoice/migration/<env>" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '24 hours ago' +%s000) \
  --query 'events[*].message'
```

### Verify File Integrity

Spot-check a sample of transferred files:

```bash
# List first 10 transferred files
aws s3api list-objects-v2 \
  --bucket invoice-docs-<env> \
  --prefix "<source_system>/2024/" \
  --max-items 10 \
  --query 'Contents[*].{Key: Key, Size: Size}'
```

## 7. Network Paths

### QA/Stage: Internet + TLS

DataSync agent connects to the S3 VPC endpoint through the VPC.
File share access is over the local network or VPN.

### Prod: AWS Direct Connect (recommended)

For production migrations with large data volumes:
1. DataSync agent is deployed in the same VPC
2. Connects to the file share via Direct Connect private VIF
3. Writes to S3 via VPC Gateway Endpoint (no internet traversal)

This provides consistent bandwidth and lower latency for the production
migration window.
