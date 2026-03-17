# Database Schema Documentation

This document describes the Aurora PostgreSQL schema for the Invoice Document Storage platform, including table design, partitioning strategy, indexing, roles, triggers, and migration helpers.

## Table of Contents

- [Overview](#overview)
- [Schema: invoice_docs](#schema-invoice_docs)
- [Custom Types](#custom-types)
- [Table: documents](#table-documents)
- [Table: invoice_details](#table-invoice_details)
- [Table: collection_letter_details](#table-collection_letter_details)
- [Partitioning Strategy](#partitioning-strategy)
- [Indexes](#indexes)
- [Triggers](#triggers)
- [Database Roles](#database-roles)
- [Migration Helpers](#migration-helpers)
- [Common Queries](#common-queries)
- [Schema Maintenance](#schema-maintenance)

## Overview

The database runs on **Aurora PostgreSQL 16.2** with the following characteristics:

| Property | Value |
|---|---|
| Engine | Aurora PostgreSQL 16.2 |
| Schema | `invoice_docs` |
| Partitioning | RANGE by `received_date` (yearly) |
| Primary keys | UUID (`gen_random_uuid()`) |
| Timestamps | `TIMESTAMPTZ` with automatic `updated_at` trigger |
| Money values | `BIGINT` in cents (e.g., `$123.45` = `12345`) |
| Source systems | `VARCHAR(50)` (not ENUM — supports any system) |
| SSL | Enforced via `rds.force_ssl = 1` parameter |

## Schema: invoice_docs

All objects are created in the `invoice_docs` schema to isolate them from the default `public` schema:

```sql
CREATE SCHEMA IF NOT EXISTS invoice_docs;
SET search_path TO invoice_docs;
```

## Custom Types

### document_kind

```sql
CREATE TYPE document_kind AS ENUM ('invoice', 'collection_letter');
```

Extensible — add new types with:
```sql
ALTER TYPE invoice_docs.document_kind ADD VALUE 'credit_memo';
```

**Note:** PostgreSQL ENUM values cannot be removed or renamed once added. Plan new values carefully.

### document_status

```sql
CREATE TYPE document_status AS ENUM ('active', 'archived', 'deleted');
```

Soft-delete pattern: documents are never physically deleted; they transition to `'deleted'` status.

### source_system

**Not an ENUM** — stored as `VARCHAR(50)` to support any source system without schema changes. Source system names are validated at the application layer, not the database layer. This allows new source systems to be onboarded without a migration.

## Table: documents

The primary table storing document metadata and S3 location. **Partitioned** by `received_date` using yearly RANGE partitions.

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `id` | UUID | NOT NULL | `gen_random_uuid()` | Document identifier |
| `document_kind` | document_kind | NOT NULL | - | Type: `invoice` or `collection_letter` |
| `source_system` | VARCHAR(50) | NOT NULL | - | Originating system (e.g., `billing_system`) |
| `account_id` | VARCHAR(20) | NOT NULL | - | Customer account identifier |
| `received_date` | DATE | NOT NULL | - | When the document was received (partition key) |
| `s3_bucket` | VARCHAR(63) | NOT NULL | - | S3 bucket name |
| `s3_key` | TEXT | NOT NULL | - | S3 object key (full path) |
| `s3_version_id` | VARCHAR(1024) | NULL | - | S3 version ID (populated after upload) |
| `file_size_bytes` | BIGINT | NULL | - | PDF file size in bytes |
| `content_hash_sha256` | CHAR(64) | NULL | - | SHA-256 hash of PDF content |
| `status` | document_status | NOT NULL | `'active'` | Document lifecycle status |
| `legacy_source_table` | VARCHAR(100) | NULL | - | Legacy SQL Server table name |
| `legacy_source_id` | BIGINT | NULL | - | Legacy row ID for traceability |
| `created_at` | TIMESTAMPTZ | NOT NULL | `now()` | Row creation timestamp |
| `updated_at` | TIMESTAMPTZ | NOT NULL | `now()` | Last update timestamp (auto-trigger) |

### Constraints

| Constraint | Columns | Type |
|---|---|---|
| Primary Key | `(id, received_date)` | Composite PK (required for partitioned tables) |
| `uq_s3_key` | `(s3_key)` | UNIQUE — prevents duplicate S3 paths |
| `uq_legacy` | `(legacy_source_table, legacy_source_id)` | UNIQUE — prevents duplicate legacy imports |

### S3 Key Format

The `s3_key` follows the convention:
```
{source_system}/{year}/{month}/{account_id}/{document_uuid}.pdf
```

Example: `billing_system/2024/03/ACC-00123456/d4e5f6a7-b8c9-1234-5678-abcdef012345.pdf`

## Table: invoice_details

Stores invoice-specific metadata. One row per invoice document.

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `id` | UUID | NOT NULL | `gen_random_uuid()` | Detail record identifier |
| `document_id` | UUID | NOT NULL | - | Reference to `documents.id` (trigger-enforced) |
| `invoice_number` | VARCHAR(50) | NOT NULL | - | Invoice number from source system |
| `invoice_date` | DATE | NOT NULL | - | Invoice issue date |
| `due_date` | DATE | NULL | - | Payment due date |
| `amount_cents` | BIGINT | NOT NULL | - | Invoice amount in cents |
| `currency_code` | CHAR(3) | NOT NULL | `'USD'` | ISO 4217 currency code |
| `billing_period_start` | DATE | NULL | - | Service period start |
| `billing_period_end` | DATE | NULL | - | Service period end |
| `service_address` | TEXT | NULL | - | Service location address |
| `created_at` | TIMESTAMPTZ | NOT NULL | `now()` | Row creation timestamp |
| `updated_at` | TIMESTAMPTZ | NOT NULL | `now()` | Last update timestamp |

### Constraints

| Constraint | Columns | Type |
|---|---|---|
| Primary Key | `(id)` | Standard PK |
| `uq_invoice_number` | `(invoice_number)` | UNIQUE — prevents duplicate invoice numbers |
| `trg_invoice_details_fk` | `(document_id)` | Trigger-enforced FK to `documents.id` |

### Why Trigger-Based FK?

PostgreSQL 16 does not support standard `FOREIGN KEY` references to a partitioned table unless the FK includes the partition key. Since `invoice_details.document_id` references `documents.id` without `received_date`, a standard FK is not possible.

The `enforce_document_fk()` trigger validates that `document_id` exists in the `documents` table before allowing INSERT or UPDATE.

## Table: collection_letter_details

Stores collection letter-specific metadata.

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `id` | UUID | NOT NULL | `gen_random_uuid()` | Detail record identifier |
| `document_id` | UUID | NOT NULL | - | Reference to `documents.id` (trigger-enforced) |
| `letter_type` | VARCHAR(50) | NOT NULL | - | Letter type (e.g., `30_day`, `60_day`, `final`) |
| `letter_date` | DATE | NOT NULL | - | Letter issue date |
| `balance_due_cents` | BIGINT | NOT NULL | - | Outstanding balance in cents |
| `previous_invoice_id` | UUID | NULL | - | FK to `invoice_details.id` (standard FK) |
| `sent_via` | VARCHAR(20) | NULL | - | Delivery method (e.g., `mail`, `email`) |
| `created_at` | TIMESTAMPTZ | NOT NULL | `now()` | Row creation timestamp |
| `updated_at` | TIMESTAMPTZ | NOT NULL | `now()` | Last update timestamp |

### Constraints

| Constraint | Columns | Type |
|---|---|---|
| Primary Key | `(id)` | Standard PK |
| FK `previous_invoice_id` | `(previous_invoice_id)` | Standard FK to `invoice_details(id) ON DELETE SET NULL` |
| `trg_collection_letter_fk` | `(document_id)` | Trigger-enforced FK to `documents.id` |

## Partitioning Strategy

### Current Partitions

```
documents_y2015  →  2015-01-01 to 2016-01-01
documents_y2016  →  2016-01-01 to 2017-01-01
documents_y2017  →  2017-01-01 to 2018-01-01
documents_y2018  →  2018-01-01 to 2019-01-01
documents_y2019  →  2019-01-01 to 2020-01-01
documents_y2020  →  2020-01-01 to 2021-01-01
documents_y2021  →  2021-01-01 to 2022-01-01
documents_y2022  →  2022-01-01 to 2023-01-01
documents_y2023  →  2023-01-01 to 2024-01-01
documents_y2024  →  2024-01-01 to 2025-01-01
documents_y2025  →  2025-01-01 to 2026-01-01
documents_y2026  →  2026-01-01 to 2027-01-01
documents_default → catch-all for dates outside defined ranges
```

### Auto-Creation Function

The `create_yearly_partition()` function creates new partitions without downtime:

```sql
SELECT invoice_docs.create_yearly_partition(2028);
-- Returns: "Created partition documents_y2028"

-- Calling again is safe (idempotent)
SELECT invoice_docs.create_yearly_partition(2028);
-- Returns: "Partition documents_y2028 already exists"
```

### Scheduling Partition Creation

**Option A: pg_cron** (if available on Aurora)
```sql
SELECT cron.schedule('create-yearly-partition', '0 0 1 12 *',
  $$SELECT invoice_docs.create_yearly_partition(
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER + 1
  )$$);
```

**Option B: Lambda + EventBridge** (scheduled annually)
- Create a Lambda function that connects to Aurora and calls `create_yearly_partition()`
- Schedule via EventBridge rule to run every December 1st

### Benefits of Partitioning

1. **Query performance** — Queries filtering by `received_date` only scan relevant partitions (partition pruning)
2. **Maintenance** — VACUUM and ANALYZE can run per-partition without blocking the whole table
3. **Data lifecycle** — Old partitions can be archived or detached without affecting active data
4. **Index management** — Each partition has its own indexes, reducing index size and rebuild time

## Indexes

| Index Name | Table | Columns | Type | Purpose |
|---|---|---|---|---|
| `idx_documents_account_received` | documents | `(account_id, received_date DESC)` | B-tree | Customer document lookup |
| `idx_documents_kind_date` | documents | `(document_kind, received_date DESC)` | B-tree | Filter by document type |
| `idx_documents_source_system` | documents | `(source_system)` | B-tree | Filter by source system |
| `idx_documents_status` | documents | `(status) WHERE status != 'deleted'` | Partial B-tree | Active document queries |
| `idx_documents_legacy` | documents | `(legacy_source_table, legacy_source_id) WHERE legacy_source_id IS NOT NULL` | Partial B-tree | Migration lookup |
| `idx_invoice_number` | invoice_details | `(invoice_number)` | B-tree | Invoice number search |
| `idx_invoice_details_document_id` | invoice_details | `(document_id)` | B-tree | Join performance |
| `idx_collection_letter_document_id` | collection_letter_details | `(document_id)` | B-tree | Join performance |

### Partial Indexes

Two indexes use `WHERE` clauses to reduce index size:
- `idx_documents_status` excludes deleted documents (most queries filter for active)
- `idx_documents_legacy` excludes documents without legacy IDs (only relevant during migration)

## Triggers

### set_updated_at()

Automatically sets `updated_at = now()` on every UPDATE:

```sql
CREATE OR REPLACE FUNCTION invoice_docs.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Applied to: `documents`, `invoice_details`, `collection_letter_details`

### enforce_document_fk()

Validates that `document_id` exists in the `documents` table before INSERT or UPDATE:

```sql
CREATE OR REPLACE FUNCTION invoice_docs.enforce_document_fk()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM invoice_docs.documents WHERE id = NEW.document_id
    ) THEN
        RAISE EXCEPTION 'document_id % does not exist in documents table', NEW.document_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Applied to: `invoice_details`, `collection_letter_details`

**Performance note:** This trigger performs a SELECT on the partitioned `documents` table for every INSERT. For bulk imports, consider temporarily disabling the trigger and running validation queries afterward.

## Database Roles

### invoice_app

Used by the ingestion service (Lambda/ECS). Has SELECT, INSERT, UPDATE on all tables. **No DELETE permission** — deletions are soft-deletes via status change.

```sql
GRANT USAGE ON SCHEMA invoice_docs TO invoice_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA invoice_docs TO invoice_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA invoice_docs TO invoice_app;

-- Future tables automatically inherit these grants
ALTER DEFAULT PRIVILEGES IN SCHEMA invoice_docs
    GRANT SELECT, INSERT, UPDATE ON TABLES TO invoice_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA invoice_docs
    GRANT USAGE ON SEQUENCES TO invoice_app;
```

### invoice_readonly

Used by reporting and BI tools. Has SELECT-only access.

```sql
GRANT USAGE ON SCHEMA invoice_docs TO invoice_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA invoice_docs TO invoice_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA invoice_docs
    GRANT SELECT ON TABLES TO invoice_readonly;
```

### Creating Application Users

The roles above are `NOLOGIN` roles. Create users and grant them the appropriate role:

```sql
-- Create an application user
CREATE USER app_service WITH PASSWORD '...' IN ROLE invoice_app;

-- Create a read-only user
CREATE USER bi_reader WITH PASSWORD '...' IN ROLE invoice_readonly;
```

In practice, Aurora manages the master user via Secrets Manager. Application services connect using the master credentials and execute queries within the `invoice_app` role's permissions.

## Migration Helpers

The `database/migration_helpers.sql` file provides:

### legacy_id_map View

Maps legacy document IDs to new UUIDs for traceability:

```sql
SELECT * FROM invoice_docs.legacy_id_map
WHERE legacy_source_table = 'Invoices_2020'
  AND legacy_source_id = 12345;
```

### Validation Queries

6 queries for verifying migration integrity:

1. **Row count comparison** — Compare source vs. destination counts per table/year
2. **Orphan detection** — Find detail records without a matching document
3. **S3 key format validation** — Verify all S3 keys match the expected pattern
4. **Duplicate legacy ID detection** — Find unexpected duplicates
5. **Missing content hash** — Find documents without SHA-256 hashes (to be backfilled)
6. **File size validation** — Find documents with zero or NULL file sizes

## Common Queries

### Documents per source system and year

```sql
SELECT
    source_system,
    EXTRACT(YEAR FROM received_date) AS year,
    COUNT(*) AS doc_count
FROM invoice_docs.documents
WHERE status = 'active'
GROUP BY source_system, EXTRACT(YEAR FROM received_date)
ORDER BY source_system, year;
```

### Total storage per source system

```sql
SELECT
    source_system,
    COUNT(*) AS doc_count,
    pg_size_pretty(SUM(file_size_bytes)) AS total_size,
    pg_size_pretty(AVG(file_size_bytes)::bigint) AS avg_size
FROM invoice_docs.documents
WHERE file_size_bytes IS NOT NULL
GROUP BY source_system
ORDER BY SUM(file_size_bytes) DESC;
```

### Recent ingestion activity

```sql
SELECT
    DATE(created_at) AS ingestion_date,
    source_system,
    COUNT(*) AS docs_ingested
FROM invoice_docs.documents
WHERE created_at > CURRENT_DATE - INTERVAL '7 days'
GROUP BY DATE(created_at), source_system
ORDER BY ingestion_date DESC, source_system;
```

### Partition sizes

```sql
SELECT
    c.relname AS partition,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    pg_size_pretty(pg_indexes_size(c.oid)) AS index_size,
    s.n_live_tup AS row_count
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relispartition AND n.nspname = 'invoice_docs'
ORDER BY c.relname;
```

## Schema Maintenance

### Adding a New Document Kind

```sql
ALTER TYPE invoice_docs.document_kind ADD VALUE 'credit_memo';
-- Then create a new detail table if needed (e.g., credit_memo_details)
```

### Adding a New Column

```sql
ALTER TABLE invoice_docs.documents ADD COLUMN metadata JSONB;
-- Existing rows will have NULL; no table rewrite needed
```

### Rebuilding Indexes

```sql
-- Rebuild a specific index (non-blocking)
REINDEX INDEX CONCURRENTLY invoice_docs.idx_documents_account_received;

-- Rebuild all indexes on a partition (non-blocking)
REINDEX TABLE CONCURRENTLY invoice_docs.documents_y2024;
```

### Analyzing Table Statistics

```sql
-- Analyze all partitions (update query planner statistics)
ANALYZE invoice_docs.documents;

-- Analyze a specific partition
ANALYZE invoice_docs.documents_y2024;
```
