# DataSync Setup Guide

This guide covers migrating document files (PDFs) from a legacy Windows file share to the S3 document storage bucket using AWS DataSync.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
- [Step 1: Deploy DataSync Agent](#step-1-deploy-datasync-agent)
- [Step 2: Create Source Location (SMB)](#step-2-create-source-location-smb)
- [Step 3: Create Destination Location (S3)](#step-3-create-destination-location-s3)
- [Step 4: Create DataSync Task](#step-4-create-datasync-task)
- [Step 5: Execute DataSync Task](#step-5-execute-datasync-task)
- [Step 6: Validation](#step-6-validation)
- [Bandwidth Configuration](#bandwidth-configuration)
- [Network Paths](#network-paths)
- [Incremental Sync for Cutover](#incremental-sync-for-cutover)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)

## Overview

AWS DataSync copies files from the legacy Windows file share to the S3 document bucket. It handles:

- **File transfer** — Copies PDFs from SMB share to S3 with TLS encryption in transit
- **Integrity verification** — Verifies file checksums after transfer
- **Filtering** — Only copies `*.pdf` files (excludes temp files, metadata, etc.)
- **Incremental transfers** — Subsequent runs only copy new or changed files

**Important:** DataSync handles the **file** migration. The **metadata** migration (SQL Server -> Aurora PostgreSQL) is handled separately by `metadata_etl.py`.

## Prerequisites

- AWS CLI v2 installed and configured
- Network connectivity between the DataSync agent and the Windows file share (SMB port 445)
- Terraform infrastructure deployed (IAM role `invoice-migration-{env}`, S3 bucket `invoice-docs-{env}`)
- Legacy file share credentials stored in AWS Secrets Manager as `invoice-fileshare-{env}`
- Windows file share accessible via SMB (Server Message Block) protocol

### Secrets Manager Entry Format

Create a secret named `invoice-fileshare-{env}` with:

```json
{
  "username": "DOMAIN\\service_account",
  "password": "file_share_password",
  "domain": "CORP"
}
```

## Architecture

```
┌─────────────────────┐     SMB (445)     ┌──────────────────┐
│ Windows File Share   │ ──────────────── │ DataSync Agent   │
│ \\server\invoices    │                  │ (EC2 m5.2xlarge) │
└─────────────────────┘                  └────────┬─────────┘
                                                   │
                                           TLS/HTTPS (via VPC
                                           Endpoint or NAT)
                                                   │
                                         ┌─────────▼─────────┐
                                         │ S3 Bucket          │
                                         │ invoice-docs-{env} │
                                         │ SSE-KMS encrypted  │
                                         └────────────────────┘
```

## Step 1: Deploy DataSync Agent

### Option A: EC2-based Agent (Recommended)

Best for VPC deployments where the file share is accessible via Direct Connect or VPN.

```bash
# Find the latest DataSync AMI
DATASYNC_AMI=$(aws ssm get-parameter \
  --name /aws/service/datasync/ami \
  --region us-east-1 \
  --query "Parameter.Value" \
  --output text)

echo "DataSync AMI: $DATASYNC_AMI"

# Launch EC2 instance in a subnet with access to the file share
aws ec2 run-instances \
  --image-id "$DATASYNC_AMI" \
  --instance-type m5.2xlarge \
  --subnet-id <subnet-id-with-file-share-access> \
  --security-group-ids <sg-id-allowing-smb-and-https> \
  --key-name <your-keypair> \
  --iam-instance-profile Name=<instance-profile-name> \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=invoice-datasync-agent},{Key=Environment,Value='$ENV'},{Key=Project,Value=invoice-doc-storage}]'
```

**Security group requirements for the agent:**
- Outbound: HTTPS (443) to AWS DataSync endpoints
- Outbound: SMB (445) to the Windows file share
- Inbound: HTTP (80) from your IP (for initial agent activation only — can be removed after)

Wait for the instance to be running, then activate:

```bash
# Get the agent's private IP
AGENT_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=invoice-datasync-agent" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# Get the activation key (from the agent's web console on port 80)
# Navigate to http://$AGENT_IP in a browser, or:
ACTIVATION_KEY=$(curl -s "http://$AGENT_IP/?activationRegion=us-east-1&redirect_type=TEXT")

# Activate the agent
aws datasync create-agent \
  --activation-key "$ACTIVATION_KEY" \
  --agent-name "invoice-datasync-agent-$ENV" \
  --tags Key=Environment,Value=$ENV Key=Project,Value=invoice-doc-storage
```

### Option B: VMware Agent (On-Premises)

For environments where the file share is on-premises and EC2 is not suitable:

1. Download the DataSync OVA from the [AWS DataSync console](https://console.aws.amazon.com/datasync)
2. Deploy the OVA on your VMware vSphere environment
3. Ensure the VM has network access to both the file share and AWS APIs
4. Activate using the same `create-agent` command above

## Step 2: Create Source Location (SMB)

```bash
# Retrieve file share credentials from Secrets Manager
SMB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "invoice-fileshare-$ENV" \
  --query SecretString --output text)

SMB_USER=$(echo "$SMB_SECRET" | jq -r '.username')
SMB_PASS=$(echo "$SMB_SECRET" | jq -r '.password')
SMB_DOMAIN=$(echo "$SMB_SECRET" | jq -r '.domain // empty')

# Get agent ARN
AGENT_ARN=$(aws datasync list-agents \
  --query "Agents[?Name=='invoice-datasync-agent-$ENV'].AgentArn" \
  --output text)

# Create SMB source location
aws datasync create-location-smb \
  --server-hostname <windows-server-ip-or-hostname> \
  --subdirectory "/invoices" \
  --user "$SMB_USER" \
  --password "$SMB_PASS" \
  ${SMB_DOMAIN:+--domain "$SMB_DOMAIN"} \
  --agent-arns "$AGENT_ARN" \
  --tags Key=Environment,Value=$ENV Key=Project,Value=invoice-doc-storage
```

**Notes:**
- The `--subdirectory` is the share path relative to the server root (e.g., `/invoices` for `\\server\invoices`)
- Create separate source locations if different source systems have different share paths
- The SMB user must have read access to all files being migrated

## Step 3: Create Destination Location (S3)

Create one destination per source system to use the correct S3 prefix:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
MIGRATION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/invoice-migration-$ENV"

# Create S3 destination (one per source system)
aws datasync create-location-s3 \
  --s3-bucket-arn "arn:aws:s3:::invoice-docs-$ENV" \
  --subdirectory "/<source_system_name>" \
  --s3-config "BucketAccessRoleArn=$MIGRATION_ROLE_ARN" \
  --s3-storage-class STANDARD \
  --tags Key=Environment,Value=$ENV Key=Project,Value=invoice-doc-storage
```

**Example for multiple source systems:**

```bash
# Source system A
aws datasync create-location-s3 \
  --s3-bucket-arn "arn:aws:s3:::invoice-docs-$ENV" \
  --subdirectory "/billing_system" \
  --s3-config "BucketAccessRoleArn=$MIGRATION_ROLE_ARN" \
  --s3-storage-class STANDARD

# Source system B
aws datasync create-location-s3 \
  --s3-bucket-arn "arn:aws:s3:::invoice-docs-$ENV" \
  --subdirectory "/erp_system" \
  --s3-config "BucketAccessRoleArn=$MIGRATION_ROLE_ARN" \
  --s3-storage-class STANDARD
```

## Step 4: Create DataSync Task

```bash
# Get location ARNs
SOURCE_ARN=$(aws datasync list-locations \
  --query "Locations[?contains(LocationUri, 'smb://')].LocationArn" --output text)

DEST_ARN=$(aws datasync list-locations \
  --query "Locations[?contains(LocationUri, 's3://invoice-docs-$ENV')].LocationArn" --output text)

# Get CloudWatch log group ARN for migration logs
LOG_GROUP_ARN=$(aws logs describe-log-groups \
  --log-group-name-prefix "/invoice/migration/$ENV" \
  --query 'logGroups[0].arn' --output text)

# Create DataSync task
aws datasync create-task \
  --source-location-arn "$SOURCE_ARN" \
  --destination-location-arn "$DEST_ARN" \
  --name "invoice-migration-$ENV" \
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
  --cloud-watch-log-group-arn "$LOG_GROUP_ARN" \
  --tags Key=Environment,Value=$ENV Key=Project,Value=invoice-doc-storage
```

### Task Options Explained

| Option | Value | Rationale |
|---|---|---|
| `VerifyMode` | `ONLY_FILES_TRANSFERRED` | Verifies checksums of transferred files |
| `OverwriteMode` | `NEVER` | Prevents overwriting existing files in S3 |
| `Mtime` | `PRESERVE` | Preserves original file modification time |
| `PreserveDeletedFiles` | `PRESERVE` | Does not delete S3 files missing from source |
| `BytesPerSecond` | `12500000` (~100 Mbps) | Throttled for QA/Stage, unlimited for Prod |
| `TransferMode` | `CHANGED` | Only transfers new/modified files on re-run |
| `LogLevel` | `TRANSFER` | Logs each transferred file |
| Includes filter | `*.pdf` | Only transfers PDF files |

## Step 5: Execute DataSync Task

```bash
TASK_ARN=$(aws datasync list-tasks \
  --query "Tasks[?Name=='invoice-migration-$ENV'].TaskArn" --output text)

# Start the task
EXECUTION_ARN=$(aws datasync start-task-execution \
  --task-arn "$TASK_ARN" \
  --query 'TaskExecutionArn' --output text)

echo "Execution ARN: $EXECUTION_ARN"

# Monitor progress
watch -n 30 "aws datasync describe-task-execution \
  --task-execution-arn '$EXECUTION_ARN' \
  --query '{Status: Status, FilesTransferred: FilesTransferred, BytesTransferred: BytesTransferred, Duration: Result.TotalDuration}'"
```

### Execution Status Values

| Status | Meaning |
|---|---|
| `LAUNCHING` | Task is starting up |
| `PREPARING` | Scanning source and destination |
| `TRANSFERRING` | Actively copying files |
| `VERIFYING` | Verifying transferred files |
| `SUCCESS` | Completed successfully |
| `ERROR` | Failed (check CloudWatch logs) |

## Step 6: Validation

### Check Transfer Summary

```bash
aws datasync describe-task-execution \
  --task-execution-arn "$EXECUTION_ARN" \
  --query '{
    Status: Status,
    FilesTransferred: FilesTransferred,
    BytesTransferred: BytesTransferred,
    FilesVerified: FilesVerified,
    BytesWritten: BytesWritten,
    Duration: Result.TotalDuration,
    ErrorCode: Result.ErrorCode,
    ErrorDetail: Result.ErrorDetail
  }'
```

### Compare File Count: Source vs S3

```bash
# Count objects in S3 for this source system
aws s3api list-objects-v2 \
  --bucket "invoice-docs-$ENV" \
  --prefix "<source_system>/" \
  --query 'KeyCount'
```

Compare this against the source file count from the legacy system.

### Check for Transfer Errors

```bash
aws logs filter-log-events \
  --log-group-name "/invoice/migration/$ENV" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '24 hours ago' +%s000) \
  --query 'events[*].message' --output text
```

### Spot-Check File Integrity

```bash
# List sample of transferred files with sizes
aws s3api list-objects-v2 \
  --bucket "invoice-docs-$ENV" \
  --prefix "<source_system>/2024/" \
  --max-items 10 \
  --query 'Contents[*].{Key: Key, Size: Size, StorageClass: StorageClass}'

# Download a sample file and verify it opens
aws s3 cp "s3://invoice-docs-$ENV/<source_system>/2024/01/ACC-12345/sample.pdf" ./test.pdf
# Open test.pdf and verify content
```

### Verify SSE-KMS Encryption

```bash
aws s3api head-object \
  --bucket "invoice-docs-$ENV" \
  --key "<source_system>/2024/01/ACC-12345/sample.pdf" \
  --query '{SSEType: ServerSideEncryption, KMSKeyId: SSEKMSKeyId}'
```

Expected: `SSEType: aws:kms`

## Bandwidth Configuration

| Environment | Bandwidth Limit | BytesPerSecond | Notes |
|---|---|---|---|
| QA | ~100 Mbps | 12,500,000 | Throttled to avoid impacting other workloads |
| Stage | ~100 Mbps | 12,500,000 | Throttled to avoid impacting other workloads |
| Prod | Unlimited | -1 | Run during off-hours maintenance window |

### Update Bandwidth for Prod Off-Hours

```bash
# Remove throttle for production migration window
aws datasync update-task \
  --task-arn "$TASK_ARN" \
  --options '{"BytesPerSecond": -1}'

# Re-apply throttle after migration window (if task will run again)
aws datasync update-task \
  --task-arn "$TASK_ARN" \
  --options '{"BytesPerSecond": 12500000}'
```

## Network Paths

### QA/Stage: VPN + VPC Endpoints

- DataSync agent connects to the file share via VPN or Direct Connect
- File uploads to S3 go through the S3 VPC Gateway Endpoint (**no NAT charges**)
- DataSync control plane communication via HTTPS (through NAT or VPC endpoint)

### Prod: AWS Direct Connect (Recommended)

For production migrations with large data volumes:

1. DataSync agent is deployed as an EC2 instance in the VPC
2. Connects to the file share via Direct Connect private virtual interface
3. Writes to S3 via VPC Gateway Endpoint (no internet traversal, no NAT charges)
4. Provides consistent bandwidth and lower latency

## Incremental Sync for Cutover

During the cutover window, run a final incremental sync to capture files added since the last full sync:

```bash
# Start incremental execution (TransferMode: CHANGED only syncs new/modified files)
CUTOVER_EXECUTION=$(aws datasync start-task-execution \
  --task-arn "$TASK_ARN" \
  --query 'TaskExecutionArn' --output text)

# Monitor until complete
aws datasync describe-task-execution \
  --task-execution-arn "$CUTOVER_EXECUTION" \
  --query '{Status: Status, FilesTransferred: FilesTransferred}'
```

This should be much faster than the initial sync since only delta files are transferred.

## Troubleshooting

### Agent Not Activating

- Verify the agent EC2 instance has HTTP (80) inbound from your IP
- Verify the agent has HTTPS (443) outbound to `datasync.{region}.amazonaws.com`
- Check that the activation key hasn't expired (valid for ~30 minutes)

### Task Execution Fails with "Access Denied"

- Verify the migration role (`invoice-migration-{env}`) has `s3:PutObject` on the bucket
- Verify the migration role has `kms:GenerateDataKey` on the KMS key
- Check that the S3 VPC endpoint policy allows access to `invoice-docs-*`

### Slow Transfer Speed

- Check NAT Gateway bandwidth (if not using VPC endpoint for S3)
- Verify `BytesPerSecond` is set appropriately (not accidentally throttled)
- Consider upgrading the agent instance type (m5.4xlarge for higher throughput)

### SMB Connection Errors

- Verify SMB port 445 is open between the agent and the file share
- Verify credentials in Secrets Manager are correct
- Check Windows firewall rules on the file share server
- Try connecting manually: `smbclient //server/invoices -U username`

## Cleanup

After migration is complete and validated:

```bash
# Delete the DataSync task
aws datasync delete-task --task-arn "$TASK_ARN"

# Delete the locations
aws datasync delete-location --location-arn "$SOURCE_ARN"
aws datasync delete-location --location-arn "$DEST_ARN"

# Delete the agent
AGENT_ARN=$(aws datasync list-agents \
  --query "Agents[?Name=='invoice-datasync-agent-$ENV'].AgentArn" --output text)
aws datasync delete-agent --agent-arn "$AGENT_ARN"

# Terminate the agent EC2 instance
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=invoice-datasync-agent" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
```

**Note:** Do NOT remove the `invoice-migration-{env}` IAM role from Terraform immediately — it may be needed if a re-migration is required. Remove it in a later cleanup sprint.
