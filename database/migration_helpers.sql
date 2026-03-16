-- Invoice Document Storage - Migration Helper Views and Validation Queries
SET search_path TO invoice_docs;

-- =============================================================================
-- View: legacy_id_map
-- Maps every legacy (table_name, source_id) pair to the new documents.id UUID.
-- Used during migration validation and post-migration audit queries.
-- =============================================================================
CREATE OR REPLACE VIEW invoice_docs.legacy_id_map AS
SELECT
    d.legacy_source_table,
    d.legacy_source_id,
    d.id               AS new_document_id,
    d.s3_key,
    d.source_system,
    d.received_date
FROM invoice_docs.documents d
WHERE d.legacy_source_id IS NOT NULL;

-- =============================================================================
-- Validation Queries
-- Run these after each migration batch to verify data integrity.
-- =============================================================================

-- 1. Row count per source system per year
-- Expected: counts should match legacy source table row counts
SELECT
    source_system,
    EXTRACT(YEAR FROM received_date)::INT AS year,
    COUNT(*) AS row_count
FROM invoice_docs.documents
GROUP BY source_system, EXTRACT(YEAR FROM received_date)
ORDER BY source_system, year;

-- 2. Documents with no corresponding detail record (orphan check)
-- Expected: 0 rows (every document should have either an invoice_details
-- or collection_letter_details record)
SELECT
    d.id,
    d.document_kind,
    d.source_system,
    d.received_date,
    d.s3_key
FROM invoice_docs.documents d
LEFT JOIN invoice_docs.invoice_details id ON id.document_id = d.id
LEFT JOIN invoice_docs.collection_letter_details cld ON cld.document_id = d.id
WHERE id.id IS NULL
  AND cld.id IS NULL;

-- 3. S3 key format validation (must match the prefix convention regex)
-- Expected: 0 rows (all s3_key values should match the convention)
-- Convention: {source_system}/{year}/{month}/{account_id}/{document_uuid}.pdf
SELECT
    d.id,
    d.s3_key
FROM invoice_docs.documents d
WHERE d.s3_key !~ '^[a-z0-9_]+/[0-9]{4}/[0-9]{2}/[A-Za-z0-9_-]+/[a-f0-9-]+\.pdf$';

-- 4. Duplicate legacy IDs check
-- Expected: 0 rows (each legacy_source_table + legacy_source_id should be unique)
SELECT
    legacy_source_table,
    legacy_source_id,
    COUNT(*) AS duplicate_count
FROM invoice_docs.documents
WHERE legacy_source_id IS NOT NULL
GROUP BY legacy_source_table, legacy_source_id
HAVING COUNT(*) > 1;

-- 5. NULL content_hash check (every migrated doc must have a hash)
-- Expected: 0 rows for fully migrated data
SELECT
    d.id,
    d.s3_key,
    d.source_system,
    d.received_date
FROM invoice_docs.documents d
WHERE d.content_hash_sha256 IS NULL
  AND d.legacy_source_id IS NOT NULL;

-- 6. Documents where file_size_bytes is 0 or NULL
-- Expected: 0 rows for fully migrated data
SELECT
    d.id,
    d.s3_key,
    d.source_system,
    d.received_date,
    d.file_size_bytes
FROM invoice_docs.documents d
WHERE d.file_size_bytes IS NULL
   OR d.file_size_bytes = 0;
