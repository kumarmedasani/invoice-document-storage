# Cutover Checklist

## Pre-Cutover (T-7 Days)

- [ ] All QA and Stage migration runs completed with 0 errors
- [ ] Row count reconciliation shows < 0.01% discrepancy per source per year
- [ ] Aurora Prod cluster deletion protection verified ON
- [ ] S3 Object Lock verified active on Prod bucket
- [ ] DataSync task verified with `VerifyMode = ONLY_FILES_TRANSFERRED`
- [ ] Backup taken of legacy SQL Server (full backup, test restore)
- [ ] All stakeholders notified of cutover window
- [ ] Rollback contact list distributed (DBA, platform-team on-call, app owners)
- [ ] Smoke test script (`scripts/smoke-test.sh prod`) runs successfully
- [ ] CloudWatch alarms all in OK or INSUFFICIENT_DATA state
- [ ] RDS Proxy health verified in Prod

## Cutover Window (T-0, Execution)

- [ ] **T-0:00** — Freeze legacy ingestion (stop all scheduled ingest jobs)
- [ ] **T-0:05** — Confirm no in-flight jobs in legacy system
- [ ] **T-0:10** — Run final DataSync task (incremental, files added since last sync)
- [ ] **T-0:30** — Run metadata ETL for all source systems:
  ```bash
  python migration/metadata_etl.py --env prod --source <source1> \
      --table-pattern "<TablePattern1>_{year}" --document-kind invoice --year all
  python migration/metadata_etl.py --env prod --source <source2> \
      --table-pattern "<TablePattern2>_{year}" --document-kind invoice --year all
  python migration/metadata_etl.py --env prod --source <source3> \
      --table-pattern "<TablePattern3>_{year}" --document-kind collection_letter --year all
  ```
- [ ] **T-1:00** — Run validation queries from `database/migration_helpers.sql`
- [ ] **T-1:15** — Enable new ingestion service (Lambda/ECS) pointing to Prod Aurora + S3
- [ ] **T-1:20** — Smoke test: ingest one test document end-to-end
- [ ] **T-1:30** — Verify document retrievable from S3 and queryable in Aurora

## Rollback Trigger Criteria

Rollback is **mandatory** if any of the following occur within 4 hours of cutover:

- Row count discrepancy > 1% for any source system
- Any P1 application error (document not found, write failure)
- Aurora Prod connection failures lasting > 5 minutes
- KMS encryption errors on any S3 write

**Rollback window closes at T+24 hours.** After that, the legacy system is
decommissioned and rollback requires restoring from SQL Server backup.

## Rollback Procedure

- [ ] Re-enable legacy ingestion jobs
- [ ] Disable new ingestion service
- [ ] Notify stakeholders of rollback
- [ ] Preserve Aurora and S3 state for post-incident analysis (do NOT delete)
- [ ] Schedule post-mortem within 48 hours

## Post-Cutover Watch Items (First 24 Hours)

- [ ] CloudWatch alarms all in OK state
- [ ] Aurora CPU < 40% under production load
- [ ] No Glacier retrieval errors (documents in Standard tier should be instant)
- [ ] First business day: confirm all teams can access documents via new system
- [ ] S3 request metrics show expected patterns (no unusual spikes or errors)
- [ ] KMS key usage within normal bounds (no throttling)
- [ ] RDS Proxy connection count stable
- [ ] No errors in application log group (`/invoice/application/prod`)
