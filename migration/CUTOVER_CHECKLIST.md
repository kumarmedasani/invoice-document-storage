# Cutover Checklist

This document provides the complete production cutover procedure for migrating from the legacy Windows Server document storage system to the new AWS-based platform.

## Table of Contents

- [Overview](#overview)
- [Roles and Responsibilities](#roles-and-responsibilities)
- [Pre-Cutover (T-7 Days)](#pre-cutover-t-7-days)
- [Pre-Cutover (T-1 Day)](#pre-cutover-t-1-day)
- [Cutover Window (T-0)](#cutover-window-t-0-execution)
- [Post-Cutover Validation (T+1 Hour)](#post-cutover-validation-t1-hour)
- [Rollback Trigger Criteria](#rollback-trigger-criteria)
- [Rollback Procedure](#rollback-procedure)
- [Post-Cutover Watch Items (First 24 Hours)](#post-cutover-watch-items-first-24-hours)
- [Post-Cutover (T+7 Days)](#post-cutover-t7-days)
- [Legacy Decommission (T+30 Days)](#legacy-decommission-t30-days)

## Overview

**Estimated cutover window:** 2-3 hours (depending on delta sync volume)

**Cutover strategy:** Big-bang cutover with rollback capability for 24 hours.

1. Freeze legacy ingestion
2. Final incremental DataSync (files)
3. Final metadata ETL (SQL Server -> Aurora)
4. Validate data integrity
5. Enable new ingestion service
6. Smoke test end-to-end

## Roles and Responsibilities

| Role | Person/Team | Responsibility |
|---|---|---|
| Cutover Lead | Platform Team Lead | Overall coordination, go/no-go decisions |
| DBA | Database Admin | Aurora monitoring, PITR readiness, validation queries |
| Infrastructure | Platform Engineer | DataSync execution, S3 validation, Terraform |
| Application | App Team Lead | Legacy freeze, new service enablement, smoke testing |
| On-Call | On-call engineer | Monitor alarms during and after cutover |
| Stakeholders | Business owners | Notification, final go/no-go sign-off |

## Pre-Cutover (T-7 Days)

### Migration Validation

- [ ] All QA migration runs completed with **0 errors**
- [ ] All Stage migration runs completed with **0 errors**
- [ ] Row count reconciliation shows **< 0.01% discrepancy** per source system per year
- [ ] Sample documents (10+ per source system) manually verified: correct PDF content, correct metadata
- [ ] Legacy-to-new document ID mapping verified via `legacy_id_map` view

### Infrastructure Validation

- [ ] Prod Terraform `apply` completed successfully
- [ ] Aurora Prod cluster deletion protection verified **ON**:
  ```bash
  aws rds describe-db-clusters --db-cluster-identifier invoice-aurora-prod \
    --query 'DBClusters[0].DeletionProtection'
  # Expected: true
  ```
- [ ] S3 Object Lock verified active on Prod bucket:
  ```bash
  aws s3api get-object-lock-configuration --bucket invoice-docs-prod
  # Expected: ObjectLockConfiguration with GOVERNANCE mode
  ```
- [ ] RDS Proxy health verified in Prod:
  ```bash
  aws rds describe-db-proxy-targets --db-proxy-name invoice-proxy-prod \
    --query 'Targets[*].TargetHealth.State'
  # Expected: AVAILABLE
  ```
- [ ] CloudWatch alarms all in **OK** or **INSUFFICIENT_DATA** state:
  ```bash
  aws cloudwatch describe-alarms --alarm-name-prefix "aurora-" \
    --state-value ALARM --query 'MetricAlarms[*].AlarmName'
  # Expected: empty list
  ```
- [ ] Smoke test script passes:
  ```bash
  bash scripts/smoke-test.sh prod
  ```

### Operational Readiness

- [ ] DataSync task verified with `VerifyMode = ONLY_FILES_TRANSFERRED`
- [ ] Full backup of legacy SQL Server completed and **tested** (restore to a test instance)
- [ ] All stakeholders notified of cutover window (date, time, duration)
- [ ] Rollback contact list distributed:
  - DBA: (name, phone)
  - Platform on-call: (name, phone)
  - App team: (name, phone)
  - Management escalation: (name, phone)
- [ ] War room / communication channel established (e.g., Slack channel, Teams bridge)

## Pre-Cutover (T-1 Day)

- [ ] Run a **dress rehearsal** DataSync incremental sync to measure delta time
- [ ] Run a **dress rehearsal** ETL incremental run to measure delta time
- [ ] Verify new ingestion service is deployed but **disabled** (not processing documents)
- [ ] Verify CloudWatch dashboard is accessible and showing current data:
  ```
  https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=invoice-prod
  ```
- [ ] Confirm all team members have AWS console access and CLI configured
- [ ] Confirm the cutover window with stakeholders (final go/no-go)
- [ ] Take a **manual Aurora snapshot** as a safety net:
  ```bash
  aws rds create-db-cluster-snapshot \
    --db-cluster-identifier invoice-aurora-prod \
    --db-cluster-snapshot-identifier "invoice-aurora-prod-pre-cutover-$(date +%Y%m%d)"
  ```

## Cutover Window (T-0, Execution)

### T-0:00 — Freeze Legacy Ingestion

- [ ] Stop all scheduled legacy ingest jobs
- [ ] Disable all legacy document upload endpoints
- [ ] Notify users that document uploads are temporarily unavailable
- [ ] **Log the exact freeze timestamp:** `_____________`

### T-0:05 — Confirm No In-Flight Jobs

- [ ] Verify no active legacy ingestion jobs:
  ```sql
  -- Run on legacy SQL Server
  SELECT * FROM sys.dm_exec_requests WHERE status = 'running';
  ```
- [ ] Verify legacy job scheduler shows all jobs stopped
- [ ] Wait for any in-flight transactions to complete (max 5 minutes)

### T-0:10 — Run Final DataSync (Incremental)

- [ ] Execute the final DataSync task:
  ```bash
  TASK_ARN="<prod-task-arn>"
  EXEC_ARN=$(aws datasync start-task-execution \
    --task-arn "$TASK_ARN" \
    --query 'TaskExecutionArn' --output text)
  echo "Execution: $EXEC_ARN"
  ```
- [ ] Monitor until `SUCCESS`:
  ```bash
  watch -n 30 "aws datasync describe-task-execution \
    --task-execution-arn '$EXEC_ARN' \
    --query '{Status:Status, Files:FilesTransferred, Bytes:BytesTransferred}'"
  ```
- [ ] Record results: Files transferred: `_____`, Bytes: `_____`
- [ ] **If DataSync fails:** Check logs, assess if re-runnable. If not, evaluate rollback.

### T-0:30 — Run Metadata ETL (All Source Systems)

- [ ] Run ETL for each source system:
  ```bash
  # Source system 1 (invoices)
  python migration/metadata_etl.py --env prod \
    --source <source1> \
    --table-pattern "<Pattern1>_{year}" \
    --document-kind invoice --year all

  # Source system 2 (invoices)
  python migration/metadata_etl.py --env prod \
    --source <source2> \
    --table-pattern "<Pattern2>_{year}" \
    --document-kind invoice --year all

  # Source system 3 (collection letters)
  python migration/metadata_etl.py --env prod \
    --source <source3> \
    --table-pattern "<Pattern3>_{year}" \
    --document-kind collection_letter --year all
  ```
- [ ] Record ETL results per source:
  - Source 1: Inserted `_____`, Skipped `_____`, Errors `_____`
  - Source 2: Inserted `_____`, Skipped `_____`, Errors `_____`
  - Source 3: Inserted `_____`, Skipped `_____`, Errors `_____`
- [ ] **If ETL has errors > 0:** Investigate. If < 0.1%, proceed. If > 1%, evaluate rollback.

### T-1:00 — Run Validation Queries

- [ ] Execute validation queries from `database/migration_helpers.sql`:
  ```bash
  PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
    -f database/migration_helpers.sql
  ```
- [ ] Verify results:
  - [ ] Row counts match source (< 0.01% discrepancy)
  - [ ] No orphan detail records
  - [ ] All S3 keys match expected format
  - [ ] No duplicate legacy IDs
- [ ] **Record row counts:**
  - Legacy total: `_____`
  - Aurora total: `_____`
  - Discrepancy: `_____` (`_____%`)

### T-1:15 — Enable New Ingestion Service

- [ ] Deploy and enable the new ingestion service (Lambda or ECS) pointing to Prod Aurora + S3
- [ ] Verify the service is running and connected:
  ```bash
  # Check Lambda function
  aws lambda invoke --function-name invoice-ingestion-prod /dev/null \
    --query 'StatusCode'
  # Or check ECS service
  aws ecs describe-services --cluster invoice-prod \
    --services invoice-ingestion \
    --query 'services[0].runningCount'
  ```

### T-1:20 — Smoke Test: End-to-End Document Ingestion

- [ ] Upload one test document through the new ingestion pipeline
- [ ] Verify the document appears in S3:
  ```bash
  aws s3api head-object \
    --bucket invoice-docs-prod \
    --key "<expected-s3-key>" \
    --query '{Size: ContentLength, SSE: ServerSideEncryption}'
  ```
- [ ] Verify metadata is in Aurora:
  ```bash
  PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
    -c "SELECT id, s3_key, status FROM invoice_docs.documents ORDER BY created_at DESC LIMIT 1;"
  ```

### T-1:30 — Verify and Declare Cutover Complete

- [ ] All validation checks passed
- [ ] Test document uploaded and retrievable
- [ ] CloudWatch alarms all in OK state
- [ ] No errors in application log group
- [ ] **Cutover Lead declares: GO / NO-GO**
- [ ] Notify stakeholders: "Cutover complete. New system is live."
- [ ] **Record cutover completion time:** `_____________`

## Post-Cutover Validation (T+1 Hour)

- [ ] Run smoke test again: `bash scripts/smoke-test.sh prod`
- [ ] Check Aurora CPU is stable (< 40%):
  ```bash
  aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS --metric-name CPUUtilization \
    --dimensions "Name=DBClusterIdentifier,Value=invoice-aurora-prod" \
    --start-time "$(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Average
  ```
- [ ] Check S3 request metrics (no 5xx errors)
- [ ] Check RDS Proxy connection count is stable
- [ ] Check application logs for errors:
  ```bash
  aws logs filter-log-events \
    --log-group-name "/invoice/application/prod" \
    --filter-pattern '{ $.level = "ERROR" }' \
    --start-time $(date -d '1 hour ago' +%s000) \
    --query 'events | length(@)'
  ```

## Rollback Trigger Criteria

Rollback is **mandatory** if any of the following occur within 4 hours of cutover:

| Criteria | Threshold | Action |
|---|---|---|
| Row count discrepancy | > 1% for any source | Immediate rollback |
| Application errors | Any P1 error (document not found, write failure) | Investigate, rollback if not resolved in 15 min |
| Aurora connection failures | > 5 minutes continuous | Immediate rollback |
| KMS encryption errors | Any error on S3 write | Immediate rollback |
| S3 5xx errors | > 10 in 5 minutes | Investigate, rollback if not resolved in 15 min |
| Document retrieval failure | Test document not downloadable | Investigate, rollback if not resolved in 15 min |

**Rollback window closes at T+24 hours.** After that, the legacy system is decommissioned and rollback requires restoring from SQL Server backup.

## Rollback Procedure

If rollback is triggered:

### Step 1: Disable New System

- [ ] Disable the new ingestion service (stop Lambda/ECS)
- [ ] **Do NOT delete any S3 objects or Aurora data** — preserve for analysis

### Step 2: Re-Enable Legacy System

- [ ] Re-enable legacy ingestion scheduled jobs
- [ ] Re-enable legacy document upload endpoints
- [ ] Verify legacy system is processing documents

### Step 3: Notify

- [ ] Notify all stakeholders of rollback
- [ ] Update the war room / communication channel
- [ ] Notify users that the system is back to the legacy platform

### Step 4: Post-Mortem

- [ ] Preserve Aurora and S3 state for investigation (do NOT delete or modify)
- [ ] Collect all logs (application, DataSync, ETL, CloudWatch)
- [ ] Schedule post-mortem within 48 hours
- [ ] Document root cause and remediation plan
- [ ] Schedule retry cutover (if applicable)

## Post-Cutover Watch Items (First 24 Hours)

These items should be monitored continuously for the first 24 hours after cutover:

- [ ] CloudWatch alarms remain in **OK** state
- [ ] Aurora CPU utilization stays **< 40%** under production load
- [ ] Aurora database connections stable (no connection storms)
- [ ] Aurora replica lag **< 1000 ms** (if using reader instances)
- [ ] No Glacier retrieval errors (recent documents should be in Standard tier)
- [ ] S3 request metrics show expected patterns (no unusual 4xx/5xx spikes)
- [ ] KMS key usage within normal bounds (no `ThrottleCount` alarms)
- [ ] RDS Proxy connection pool utilization **< 80%**
- [ ] No errors in application log group (`/invoice/application/prod`)
- [ ] No errors in migration log group (`/invoice/migration/prod`)
- [ ] First business day: confirm all teams can access documents via the new system
- [ ] First business day: verify at least 1 new document has been ingested successfully

## Post-Cutover (T+7 Days)

- [ ] Run a comprehensive validation: compare all source systems' row counts
- [ ] Verify S3 storage metrics match expected document volumes
- [ ] Review CloudWatch dashboard for any anomalies over the first week
- [ ] Collect feedback from application teams and end users
- [ ] Remove any temporary access or elevated permissions granted for cutover
- [ ] Update documentation with any lessons learned

## Legacy Decommission (T+30 Days)

After 30 days of successful operation on the new platform:

- [ ] Confirm no rollback is needed (formal sign-off from stakeholders)
- [ ] Take a final full backup of the legacy SQL Server database
- [ ] Archive the legacy SQL Server backup to S3 Glacier Deep Archive
- [ ] Decommission the legacy ingestion jobs
- [ ] Decommission the legacy Windows file share (after confirming all files are in S3)
- [ ] Remove the DataSync agent and related resources (see `datasync-setup.md` Cleanup section)
- [ ] Optionally remove the `invoice-migration-{env}` IAM role from Terraform
- [ ] Update architecture documentation to reflect "legacy decommissioned" status
- [ ] Close the migration project
