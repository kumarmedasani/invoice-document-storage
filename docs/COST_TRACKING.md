# Cost Tracking

## Expected Monthly Costs Per Environment

| Service | QA (est.) | Stage (est.) | Prod (est.) |
|---|---|---|---|
| Aurora (cluster) | ~$60 | ~$180 | ~$350 |
| RDS Proxy | - | ~$15 | ~$15 |
| S3 (Standard, 1TB) | ~$8 | ~$23 | ~$23 |
| S3 (Glacier, 10TB) | ~$40 | ~$40 | ~$40 |
| KMS | ~$1 | ~$1 | ~$1 |
| CloudWatch | ~$5 | ~$10 | ~$20 |
| VPC Endpoints | ~$15 | ~$15 | ~$22 |
| NAT Gateway | - | ~$35 | ~$70 |
| **Total** | **~$130** | **~$320** | **~$540** |

These are estimates based on us-east-1 pricing. Validate against the
[AWS Pricing Calculator](https://calculator.aws/) before presenting to stakeholders.

## AWS Cost Explorer Setup

### Filter by CostCenter Tag

1. Open AWS Cost Explorer
2. Go to **Filters** > **Tag** > **CostCenter**
3. Select the relevant cost center:
   - QA/Stage: `IT-1042`
   - Prod: `IT-1043`

### Filter by Environment Tag

1. Open AWS Cost Explorer
2. Go to **Filters** > **Tag** > **Environment**
3. Select: `qa`, `stage`, or `prod`

### Set Up Monthly Budget Alerts

Create a budget at 120% of expected cost for each environment:

```bash
# QA budget: 120% of $130 = $156
aws budgets create-budget --account-id <account-id> --budget '{
  "BudgetName": "invoice-doc-storage-qa",
  "BudgetLimit": {"Amount": "156", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {"TagKeyValue": ["user:Environment$qa", "user:Project$invoice-doc-storage"]}
}' --notifications-with-subscribers '[{
  "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 100},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "admin@example.com"}]
}]'

# Stage budget: 120% of $320 = $384
aws budgets create-budget --account-id <account-id> --budget '{
  "BudgetName": "invoice-doc-storage-stage",
  "BudgetLimit": {"Amount": "384", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {"TagKeyValue": ["user:Environment$stage", "user:Project$invoice-doc-storage"]}
}' --notifications-with-subscribers '[{
  "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 100},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "admin@example.com"}]
}]'

# Prod budget: 120% of $540 = $648
aws budgets create-budget --account-id <account-id> --budget '{
  "BudgetName": "invoice-doc-storage-prod",
  "BudgetLimit": {"Amount": "648", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {"TagKeyValue": ["user:Environment$prod", "user:Project$invoice-doc-storage"]}
}' --notifications-with-subscribers '[{
  "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 100},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "admin@example.com"}]
}]'
```

## Cost Anomaly Detection

### Create a Cost Anomaly Monitor

```bash
aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "invoice-doc-storage-anomaly",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }'
```

Create an anomaly subscription with a $50/day threshold:

```bash
aws ce create-anomaly-subscription \
  --anomaly-subscription '{
    "SubscriptionName": "invoice-doc-storage-anomaly-alerts",
    "MonitorArnList": ["<monitor-arn>"],
    "Subscribers": [{"Address": "admin@example.com", "Type": "EMAIL"}],
    "Threshold": 50,
    "Frequency": "DAILY"
  }'
```

## S3 Storage Cost Optimization Tips

### 1. Verify Lifecycle Transitions Are Firing

```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket invoice-docs-<env> \
  --query 'Rules[*].{ID: ID, Status: Status, Transitions: Transitions}'
```

### 2. Check S3 Storage Lens for Per-Prefix Storage Class Breakdown

1. Open S3 console > Storage Lens
2. Create a dashboard filtered to `invoice-docs-*` buckets
3. Review metrics: storage by class, request counts, retrieval costs

### 3. KMS Cost Reduction

`bucket_key_enabled = true` is already configured on the S3 bucket. This
reduces KMS API calls by ~99% because S3 uses a bucket-level key to derive
per-object keys locally, rather than calling KMS for each object.

Verify it's enabled:

```bash
aws s3api get-bucket-encryption \
  --bucket invoice-docs-<env> \
  --query 'ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled'
```

### 4. Monitor NAT Gateway Data Processing Costs

NAT Gateway charges $0.045/GB for data processed. If costs are unexpectedly
high, verify that S3 traffic is routing through the VPC Gateway Endpoint
(free) rather than through the NAT Gateway:

```bash
# Check VPC endpoint routes
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'RouteTables[*].Routes[?DestinationPrefixListId != null]'
```
