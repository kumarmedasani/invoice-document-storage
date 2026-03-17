-- Invoice Document Storage - Aurora PostgreSQL Schema
-- Database: Aurora PostgreSQL 16
-- All objects created in the invoice_docs schema

-- =============================================================================
-- Schema
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS invoice_docs;
SET search_path TO invoice_docs;

-- =============================================================================
-- ENUMs
-- =============================================================================

-- document_kind: extensible enum for document types.
-- To add new types: ALTER TYPE invoice_docs.document_kind ADD VALUE 'new_type';
CREATE TYPE document_kind AS ENUM ('invoice', 'collection_letter');

CREATE TYPE document_status AS ENUM ('active', 'archived', 'deleted');

-- DECISION: source_system is VARCHAR instead of ENUM to support any source
-- system without schema changes. Validated at the application layer.

-- =============================================================================
-- Table: documents (partitioned by received_date, RANGE, yearly)
-- =============================================================================
CREATE TABLE IF NOT EXISTS documents (
    id                   UUID            NOT NULL DEFAULT gen_random_uuid(),
    document_kind        document_kind   NOT NULL,
    source_system        VARCHAR(50)     NOT NULL,
    account_id           VARCHAR(20)     NOT NULL,
    received_date        DATE            NOT NULL,
    s3_bucket            VARCHAR(63)     NOT NULL,
    s3_key               TEXT            NOT NULL,
    s3_version_id        VARCHAR(1024),
    file_size_bytes      BIGINT,
    content_hash_sha256  CHAR(64),
    status               document_status NOT NULL DEFAULT 'active',
    legacy_source_table  VARCHAR(100),
    legacy_source_id     BIGINT,
    created_at           TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ     NOT NULL DEFAULT now(),
    PRIMARY KEY (id, received_date),
    CONSTRAINT uq_s3_key UNIQUE (s3_key),
    CONSTRAINT uq_legacy UNIQUE (legacy_source_table, legacy_source_id)
) PARTITION BY RANGE (received_date);

-- Partitions: 2015-2026 + DEFAULT
CREATE TABLE IF NOT EXISTS documents_y2015 PARTITION OF documents
    FOR VALUES FROM ('2015-01-01') TO ('2016-01-01');
CREATE TABLE IF NOT EXISTS documents_y2016 PARTITION OF documents
    FOR VALUES FROM ('2016-01-01') TO ('2017-01-01');
CREATE TABLE IF NOT EXISTS documents_y2017 PARTITION OF documents
    FOR VALUES FROM ('2017-01-01') TO ('2018-01-01');
CREATE TABLE IF NOT EXISTS documents_y2018 PARTITION OF documents
    FOR VALUES FROM ('2018-01-01') TO ('2019-01-01');
CREATE TABLE IF NOT EXISTS documents_y2019 PARTITION OF documents
    FOR VALUES FROM ('2019-01-01') TO ('2020-01-01');
CREATE TABLE IF NOT EXISTS documents_y2020 PARTITION OF documents
    FOR VALUES FROM ('2020-01-01') TO ('2021-01-01');
CREATE TABLE IF NOT EXISTS documents_y2021 PARTITION OF documents
    FOR VALUES FROM ('2021-01-01') TO ('2022-01-01');
CREATE TABLE IF NOT EXISTS documents_y2022 PARTITION OF documents
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
CREATE TABLE IF NOT EXISTS documents_y2023 PARTITION OF documents
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE IF NOT EXISTS documents_y2024 PARTITION OF documents
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE IF NOT EXISTS documents_y2025 PARTITION OF documents
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE IF NOT EXISTS documents_y2026 PARTITION OF documents
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE IF NOT EXISTS documents_default PARTITION OF documents DEFAULT;

-- =============================================================================
-- Table: invoice_details
-- =============================================================================
CREATE TABLE IF NOT EXISTS invoice_details (
    id                   UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    document_id          UUID        NOT NULL,
    invoice_number       VARCHAR(50) NOT NULL,
    invoice_date         DATE        NOT NULL,
    due_date             DATE,
    amount_cents         BIGINT      NOT NULL,
    currency_code        CHAR(3)     NOT NULL DEFAULT 'USD',
    billing_period_start DATE,
    billing_period_end   DATE,
    service_address      TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_invoice_number UNIQUE (invoice_number)
);

-- DECISION: FK from invoice_details.document_id to documents.id cannot use
-- standard REFERENCES on a partitioned table in PostgreSQL 16 without
-- including the partition key. Using a trigger-based approach or application-
-- level enforcement instead. The relationship is documented here for clarity.
-- ALTER TABLE invoice_details ADD CONSTRAINT fk_document
--     FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE;

-- =============================================================================
-- Table: collection_letter_details
-- =============================================================================
CREATE TABLE IF NOT EXISTS collection_letter_details (
    id                   UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    document_id          UUID        NOT NULL,
    letter_type          VARCHAR(50) NOT NULL,
    letter_date          DATE        NOT NULL,
    balance_due_cents    BIGINT      NOT NULL,
    previous_invoice_id  UUID        REFERENCES invoice_details(id) ON DELETE SET NULL,
    sent_via             VARCHAR(20),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- Trigger: enforce FK from detail tables to documents
-- PostgreSQL 16 does not support standard FK references to partitioned tables
-- without including the partition key. This trigger enforces referential integrity.
-- =============================================================================
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

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_invoice_details_fk') THEN
        CREATE TRIGGER trg_invoice_details_fk
            BEFORE INSERT OR UPDATE ON invoice_docs.invoice_details
            FOR EACH ROW
            EXECUTE FUNCTION invoice_docs.enforce_document_fk();
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_collection_letter_fk') THEN
        CREATE TRIGGER trg_collection_letter_fk
            BEFORE INSERT OR UPDATE ON invoice_docs.collection_letter_details
            FOR EACH ROW
            EXECUTE FUNCTION invoice_docs.enforce_document_fk();
    END IF;
END
$$;

-- =============================================================================
-- Function: auto-create yearly partitions
-- Run via pg_cron or a scheduled Lambda to ensure future partitions exist.
-- =============================================================================
CREATE OR REPLACE FUNCTION invoice_docs.create_yearly_partition(target_year INTEGER)
RETURNS TEXT AS $$
DECLARE
    partition_name TEXT;
    start_date TEXT;
    end_date TEXT;
BEGIN
    partition_name := 'documents_y' || target_year;
    start_date := target_year || '-01-01';
    end_date := (target_year + 1) || '-01-01';

    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'invoice_docs' AND c.relname = partition_name
    ) THEN
        RETURN 'Partition ' || partition_name || ' already exists';
    END IF;

    EXECUTE format(
        'CREATE TABLE invoice_docs.%I PARTITION OF invoice_docs.documents FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
    );

    RETURN 'Created partition ' || partition_name;
END;
$$ LANGUAGE plpgsql;

-- Pre-create next year's partition
SELECT invoice_docs.create_yearly_partition(EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER + 1);

-- =============================================================================
-- Indexes
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_documents_account_received
    ON documents(account_id, received_date DESC);

CREATE INDEX IF NOT EXISTS idx_documents_kind_date
    ON documents(document_kind, received_date DESC);

CREATE INDEX IF NOT EXISTS idx_documents_source_system
    ON documents(source_system);

CREATE INDEX IF NOT EXISTS idx_documents_status
    ON documents(status) WHERE status != 'deleted';

CREATE INDEX IF NOT EXISTS idx_invoice_number
    ON invoice_details(invoice_number);

CREATE INDEX IF NOT EXISTS idx_documents_legacy
    ON documents(legacy_source_table, legacy_source_id)
    WHERE legacy_source_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_invoice_details_document_id
    ON invoice_details(document_id);

CREATE INDEX IF NOT EXISTS idx_collection_letter_document_id
    ON collection_letter_details(document_id);

-- =============================================================================
-- Trigger: auto-update updated_at
-- =============================================================================
CREATE OR REPLACE FUNCTION invoice_docs.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_documents_updated_at') THEN
        CREATE TRIGGER trg_documents_updated_at
            BEFORE UPDATE ON invoice_docs.documents
            FOR EACH ROW
            EXECUTE FUNCTION invoice_docs.set_updated_at();
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_invoice_details_updated_at') THEN
        CREATE TRIGGER trg_invoice_details_updated_at
            BEFORE UPDATE ON invoice_docs.invoice_details
            FOR EACH ROW
            EXECUTE FUNCTION invoice_docs.set_updated_at();
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_collection_letter_details_updated_at') THEN
        CREATE TRIGGER trg_collection_letter_details_updated_at
            BEFORE UPDATE ON invoice_docs.collection_letter_details
            FOR EACH ROW
            EXECUTE FUNCTION invoice_docs.set_updated_at();
    END IF;
END
$$;

-- =============================================================================
-- Roles and Grants
-- =============================================================================

-- Application role (used by ingestion service)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'invoice_app') THEN
        CREATE ROLE invoice_app NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA invoice_docs TO invoice_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA invoice_docs TO invoice_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA invoice_docs TO invoice_app;
-- No DELETE permission for application role — deletions are status updates only

-- Ensure future tables/sequences also get the correct grants
ALTER DEFAULT PRIVILEGES IN SCHEMA invoice_docs
    GRANT SELECT, INSERT, UPDATE ON TABLES TO invoice_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA invoice_docs
    GRANT USAGE ON SEQUENCES TO invoice_app;

-- Read-only role (used by reporting/BI tools)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'invoice_readonly') THEN
        CREATE ROLE invoice_readonly NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA invoice_docs TO invoice_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA invoice_docs TO invoice_readonly;

-- Ensure future tables are also readable
ALTER DEFAULT PRIVILEGES IN SCHEMA invoice_docs
    GRANT SELECT ON TABLES TO invoice_readonly;
