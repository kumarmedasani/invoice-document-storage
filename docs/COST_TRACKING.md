# Cost Tracking

This document covers cost estimation, budget setup, anomaly detection, and optimization strategies for the Invoice Document Storage platform.

## Table of Contents

- [Expected Monthly Costs](#expected-monthly-costs)
- [Cost Breakdown by Service](#cost-breakdown-by-service)
- [AWS Cost Explorer Setup](#aws-cost-explorer-setup)
- [Budget Alerts](#budget-alerts)
- [Cost Anomaly Detection](#cost-anomaly-detection)
- [Optimization Strategies](#optimization-strategies)
- [Cost Scaling Projections](#cost-scaling-projections)

## Expected Monthly Costs

All estimates are based on us-east-1 pricing as of 2024. Validate against the [AWS Pricing Calculator](https://calculator.aws/) before presenting to stakeholders.

| Service | QA (est.) | Stage (est.) | Prod (est.) | Notes |
|---|---|---|---|---|
| Aurora PostgreSQL (cluster) | ~$60 | ~$180 | ~$350 | Instance hours + storage |
| Aurora Storage | ~$5 | ~$10 | ~$25 | $0.10/GB-month, grows with data |
| RDS Proxy | - | ~$15 | ~$15 | $0.015/vCPU-hour |
| S3 Standard (1 TB) | ~$8 | ~$23 | ~$23 | $0.023/GB-month |
| S3 Glacier (10 TB) | - | - | ~$40 | $0.004/GB-month |
| S3 Deep Archive (50 TB) | - | - | ~$50 | $0.00099/GB-month |
| S3 Landing Zone Bucket | < $1 | < $1 | < $1 | Transient files, 7-day expiry |
| S3 Access Logging Bucket | ~$1 | ~$1 | ~$2 | Minimal storage, 90-day expiry |
| KMS | ~$1 | ~$1 | ~$1 | $1/key/month + API calls |
| CloudWatch Logs | ~$3 | ~$5 | ~$10 | Ingestion + storage |
| CloudWatch Alarms (9) | ~$1 | ~$1 | ~$1 | $0.10/alarm/month |
| SQS (Lambda DLQ) | < $1 | < $1 | < $1 | Free tier covers most; pay-per-message |
| CloudWatch Dashboard | ~$3 | ~$3 | ~$3 | $3/dashboard/month |
| VPC Endpoints (5 Interface) | ~$19 | ~$19 | ~$28 | $0.01/hour/AZ + data |
| AWS Transfer Family (SFTP) | ~$22 | ~$22 | ~$22 | $0.30/hour for SFTP server |
| VPC Flow Logs | ~$2 | ~$2 | ~$5 | CloudWatch Logs ingestion |
| Kinesis Firehose (Splunk) | ~$5 | ~$10 | ~$20 | $0.029/GB ingested |
| S3 Firehose Backup Bucket | < $1 | < $1 | < $1 | Failed deliveries only, 14-day expiry |
| Lambda (Ingestion) | < $1 | < $1 | ~$1 | Free tier covers most; scales with invocations |
| SNS (2 topics) | < $1 | < $1 | < $1 | Alerts + file notifications |
| Data Transfer | ~$2 | ~$5 | ~$10 | Within-AZ mostly free |
| **Monthly Total** | **~$136** | **~$303** | **~$613** | |
| **Annual Total** | **~$1,632** | **~$3,636** | **~$7,356** | |

### Cost Notes

- **No NAT Gateway** — All environments use VPC endpoints instead of NAT Gateways, eliminating ~$35-96/month in NAT costs
- **AWS Transfer Family** costs $0.30/hour (~$219/month) for the SFTP server plus $0.04/GB for data uploaded
- **Lambda ingestion** is effectively free at low volume — the AWS Free Tier includes 1M requests and 400,000 GB-seconds/month. At 10,000 files/month with 512 MB / 5s average, costs are ~$0.20/month
- **S3 landing zone** costs are negligible — files are transient (7-day expiry) and deleted by Lambda after processing
- **S3 costs scale with data volume** — the Glacier and Deep Archive estimates assume steady-state after migration
- **KMS bucket keys** reduce KMS API costs by ~99% — S3 uses a bucket-level key instead of per-object KMS calls
- **VPC endpoint costs increase with AZ count** — Prod has 3 AZs vs. 2 for QA/Stage ($7.50/endpoint/AZ/month). 5 interface endpoints: Secrets Manager, KMS, CloudWatch Monitoring, CloudWatch Logs, STS
- **Kinesis Firehose** charges $0.029/GB of data ingested. At 5 GB/day of logs, that's ~$4.50/month. Costs scale with log volume
- **Splunk streaming is optional** — set `splunk_hec_endpoint = ""` (default) to disable Firehose and eliminate this cost entirely

## Cost Breakdown by Service

### Aurora PostgreSQL

| Component | Unit Price | QA | Stage | Prod |
|---|---|---|---|---|
| db.t4g.medium (1 instance) | $0.082/hr | $60/mo | - | - |
| db.t4g.large (2 instances) | $0.164/hr | - | $240/mo | - |
| db.r8g.large (2 instances) | $0.24/hr | - | - | $350/mo |
| Storage (per GB) | $0.10/GB | ~$5 | ~$10 | ~$25 |
| Backup storage | Free up to cluster size | $0 | $0 | $0 |
| Performance Insights | Free (retention ≤ 7 days) | - | $0 | $0 |

### S3 Storage

| Storage Class | Price/GB/month | Retrieval Cost | Minimum Duration |
|---|---|---|---|
| S3 Standard | $0.023 | Free | None |
| Glacier Flexible Retrieval | $0.004 | $0.01/GB (Standard) | 90 days |
| Glacier Deep Archive | $0.00099 | $0.02/GB (Standard) | 180 days |

### VPC Endpoints

| Type | Cost | Count per Env |
|---|---|---|
| S3 Gateway | **Free** | 1 |
| Interface (per AZ) | $0.01/hour = ~$7.50/month | 5 services x N AZs |

5 interface endpoints: Secrets Manager, KMS, CloudWatch Monitoring, CloudWatch Logs, STS. The VPC endpoint hourly rate applies per endpoint-per-AZ.

### AWS Transfer Family (SFTP)

| Component | Cost |
|---|---|
| SFTP server (per hour) | $0.30/hour (~$219/month) |
| Data upload (per GB) | $0.04/GB |

The SFTP server runs 24/7. Data upload costs depend on vendor volume — at 100 GB/month, transfer costs are ~$4/month.

### Kinesis Data Firehose (Splunk Streaming)

| Component | Cost |
|---|---|
| Data ingestion (per GB) | $0.029/GB |
| S3 backup bucket (failed deliveries) | $0.023/GB (14-day expiry, negligible) |

Firehose costs scale linearly with log volume. At 5 GB/day of CloudWatch Logs, monthly cost is ~$4.50. Splunk streaming is disabled by default (`splunk_hec_endpoint = ""`).

## AWS Cost Explorer Setup

### Filter by CostCenter Tag

1. Open [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home#/cost-explorer)
2. Click **Filters** > **Tag** > **CostCenter**
3. Select the relevant cost center:
   - QA/Stage: value from `terraform.tfvars` (e.g., `IT-1042`)
   - Prod: value from `terraform.tfvars` (e.g., `IT-1043`)

### Filter by Environment Tag

1. Open Cost Explorer
2. Click **Filters** > **Tag** > **Environment**
3. Select: `qa`, `stage`, or `prod`

### Filter by Project Tag

All resources are tagged with `Project = invoice-doc-storage`. Use this tag to see the total project cost across environments:

1. Click **Filters** > **Tag** > **Project**
2. Select: `invoice-doc-storage`

### Create a Saved Report

1. Configure your desired filters and date range
2. Click **Save as** and name it (e.g., "Invoice Doc Storage - Prod Monthly")
3. Share the report URL with stakeholders

## Budget Alerts

Create AWS Budget alerts at 80% and 100% of expected monthly cost for each environment.

### Create Budget via CLI

```bash
ACCOUNT_ID="YOUR_ACCOUNT_ID"
ALERT_EMAIL="admin@example.com"

# QA budget: $150 (includes buffer over ~$100 estimate)
aws budgets create-budget --account-id "$ACCOUNT_ID" --budget '{
  "BudgetName": "invoice-doc-storage-qa",
  "BudgetLimit": {"Amount": "150", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {
    "TagKeyValue": [
      "user:Environment$qa",
      "user:Project$invoice-doc-storage"
    ]
  }
}' --notifications-with-subscribers '[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "'$ALERT_EMAIL'"}]
  },
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 100
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "'$ALERT_EMAIL'"}]
  }
]'

# Stage budget: $400
aws budgets create-budget --account-id "$ACCOUNT_ID" --budget '{
  "BudgetName": "invoice-doc-storage-stage",
  "BudgetLimit": {"Amount": "400", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {
    "TagKeyValue": [
      "user:Environment$stage",
      "user:Project$invoice-doc-storage"
    ]
  }
}' --notifications-with-subscribers '[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "'$ALERT_EMAIL'"}]
  },
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 100
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "'$ALERT_EMAIL'"}]
  }
]'

# Prod budget: $800
aws budgets create-budget --account-id "$ACCOUNT_ID" --budget '{
  "BudgetName": "invoice-doc-storage-prod",
  "BudgetLimit": {"Amount": "800", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {
    "TagKeyValue": [
      "user:Environment$prod",
      "user:Project$invoice-doc-storage"
    ]
  }
}' --notifications-with-subscribers '[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "'$ALERT_EMAIL'"}]
  },
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 100
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "'$ALERT_EMAIL'"}]
  }
]'
```

### Verify Budgets

```bash
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[?starts_with(BudgetName, `invoice-`)].{Name: BudgetName, Limit: BudgetLimit.Amount, Actual: CalculatedSpend.ActualSpend.Amount}'
```

## Cost Anomaly Detection

### Create a Cost Anomaly Monitor

```bash
# Create monitor for the project
MONITOR_ARN=$(aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "invoice-doc-storage-anomaly",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }' \
  --query 'MonitorArn' --output text)

echo "Monitor ARN: $MONITOR_ARN"
```

### Create Anomaly Subscription

Set up alerts for anomalies exceeding $50/day:

```bash
aws ce create-anomaly-subscription \
  --anomaly-subscription '{
    "SubscriptionName": "invoice-doc-storage-anomaly-alerts",
    "MonitorArnList": ["'$MONITOR_ARN'"],
    "Subscribers": [{"Address": "'$ALERT_EMAIL'", "Type": "EMAIL"}],
    "Threshold": 50,
    "Frequency": "DAILY"
  }'
```

This sends a daily email if any service associated with the project has a cost spike exceeding $50 above the expected baseline.

## Optimization Strategies

### 1. Verify S3 Lifecycle Transitions Are Active

If objects are not transitioning to Glacier as expected, storage costs will be higher than projected.

```bash
# Check lifecycle configuration
aws s3api get-bucket-lifecycle-configuration \
  --bucket "invoice-docs-$ENV" \
  --query 'Rules[*].{ID: ID, Status: Status, Transitions: Transitions, Expiration: Expiration}'

# Check storage class distribution
aws s3api list-objects-v2 \
  --bucket "invoice-docs-$ENV" \
  --prefix "billing_system/2020/" \
  --query 'Contents[*].StorageClass' \
  --output text | sort | uniq -c | sort -rn
```

### 2. S3 Storage Lens Dashboard

For a visual breakdown of storage costs by prefix and storage class:

1. Open S3 console > **Storage Lens**
2. Create a new dashboard filtered to `invoice-docs-*` buckets
3. Enable **Advanced metrics** (additional cost: $0.20/million objects/month)
4. Review: storage by class, request counts, retrieval costs per prefix

### 3. KMS Cost Reduction — S3 Bucket Keys

S3 Bucket Keys are already enabled (`bucket_key_enabled = true`), reducing KMS API calls by ~99%. Verify:

```bash
aws s3api get-bucket-encryption \
  --bucket "invoice-docs-$ENV" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled'
# Should return: true
```

Without bucket keys, every S3 PutObject/GetObject would call KMS, at $0.03 per 10,000 requests. With bucket keys, S3 generates per-object keys locally.

### 4. Verify VPC Endpoint Routing

Ensure S3 traffic uses the VPC Gateway Endpoint (free) rather than any other path:

```bash
# Check route tables have S3 endpoint route
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'RouteTables[*].{Name: Tags[?Key==`Name`].Value | [0], Routes: Routes[?DestinationPrefixListId != null].{PrefixList: DestinationPrefixListId, Target: VpcEndpointId}}'
```

Every route table (app and data tiers) should show an S3 prefix list route pointing to the VPC Gateway Endpoint.

### 5. Aurora Right-Sizing

Monitor CPU utilization over a 30-day period. If average CPU is consistently below 20%, consider downsizing:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions "Name=DBClusterIdentifier,Value=invoice-aurora-$ENV" \
  --start-time "$(date -d '30 days ago' -u +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 86400 \
  --statistics Average \
  --query 'Datapoints | sort_by(@, &Timestamp) | [-7:].{Date: Timestamp, AvgCPU: Average}'
```

### 6. Shut Down QA Off-Hours (Optional)

QA does not have deletion protection. To save costs, stop Aurora during non-business hours:

```bash
# Stop (saves compute cost, storage still charged)
aws rds stop-db-cluster --db-cluster-identifier invoice-aurora-qa

# Start (before next business day)
aws rds start-db-cluster --db-cluster-identifier invoice-aurora-qa
```

**Note:** Aurora automatically restarts after 7 days if stopped. Consider automating start/stop with a Lambda function on a CloudWatch Events schedule.

## Cost Scaling Projections

### Storage Growth Impact

| Scenario | Year 1 S3 Cost | Year 5 S3 Cost | Year 10 S3 Cost |
|---|---|---|---|
| 100K docs/year (avg 500KB) | ~$14/mo | ~$28/mo (mostly Glacier) | ~$15/mo (mostly Deep Archive) |
| 1M docs/year (avg 500KB) | ~$140/mo | ~$280/mo | ~$150/mo |
| 10M docs/year (avg 500KB) | ~$1,400/mo | ~$2,800/mo | ~$1,500/mo |

Storage costs decrease significantly over time as older data transitions to cheaper storage tiers (Glacier: 5.7x cheaper than Standard, Deep Archive: 23x cheaper).

### Aurora Growth Impact

Aurora storage is priced at $0.10/GB-month and auto-scales. Metadata is small (~1KB per document), so even at 10M documents, the database would only be ~10 GB.

| Documents | Aurora Storage | Monthly Cost |
|---|---|---|
| 1M | ~1 GB | ~$0.10 |
| 10M | ~10 GB | ~$1.00 |
| 100M | ~100 GB | ~$10.00 |

Aurora compute costs dominate; storage is negligible for metadata workloads.
