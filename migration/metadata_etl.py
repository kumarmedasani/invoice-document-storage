#!/usr/bin/env python3
"""
Invoice Document Metadata ETL

Extracts metadata from legacy SQL Server tables, transforms it, and loads
into Aurora PostgreSQL.

Usage:
    python metadata_etl.py --env qa --source billing_system --year 2020 [--dry-run]
    python metadata_etl.py --env prod --source billing_system --year all
    python metadata_etl.py --help

Source systems and legacy table patterns are configurable via CLI arguments.
"""

import argparse
import hashlib
import json
import logging
import os
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import PurePosixPath

import boto3
import psycopg2
import psycopg2.extras
import pyodbc


# =============================================================================
# Logging Setup
# =============================================================================
class JsonFormatter(logging.Formatter):
    """Structured JSON log formatter."""

    def format(self, record):
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        if record.exc_info and record.exc_info[0]:
            log_entry["exception"] = self.formatException(record.exc_info)
        if hasattr(record, "extra_data"):
            log_entry.update(record.extra_data)
        return json.dumps(log_entry)


def setup_logging(env):
    """Configure structured JSON logging to stdout."""
    logger = logging.getLogger("metadata_etl")
    logger.setLevel(logging.INFO)

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logger.addHandler(handler)

    return logger


# =============================================================================
# AWS Helpers
# =============================================================================
def get_secret(secret_name, region="us-east-1"):
    """Fetch a secret from AWS Secrets Manager and return parsed JSON."""
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])


def get_sqlserver_connection(env, region="us-east-1"):
    """Create a connection to the legacy SQL Server database."""
    secret = get_secret(f"invoice-sqlserver-{env}", region)
    conn_str = (
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER={secret['host']},{secret.get('port', 1433)};"
        f"DATABASE={secret['database']};"
        f"UID={secret['username']};"
        f"PWD={secret['password']};"
        f"Encrypt=yes;TrustServerCertificate=yes;"
    )
    return pyodbc.connect(conn_str)


def get_aurora_connection(env, region="us-east-1"):
    """Create a connection to Aurora PostgreSQL using Secrets Manager."""
    secret = get_secret(f"invoice-aurora-{env}", region)
    return psycopg2.connect(
        host=secret["host"],
        port=secret.get("port", 5432),
        database=secret.get("database", "postgres"),
        user=secret["username"],
        password=secret["password"],
        sslmode="require",
    )


# =============================================================================
# Transform Helpers
# =============================================================================
def money_to_cents(value):
    """Convert a decimal money value to integer cents."""
    if value is None:
        return 0
    d = Decimal(str(value))
    return int((d * 100).to_integral_value(rounding=ROUND_HALF_UP))


def normalize_utf8(value):
    """Normalize a string to UTF-8, handling None and bytes."""
    if value is None:
        return None
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def derive_s3_key(source_system, file_path, invoice_date, account_id):
    """
    Derive S3 key from legacy file path.

    Legacy FilePath: \\\\server\\invoices\\2020\\ACC-00123\\INV-456.pdf
    S3 key:          source_system/2020/03/ACC-00123/d4e5f6a7-....pdf

    Month is derived from the invoice/letter date.
    File is renamed to a UUID to ensure uniqueness.
    """
    if file_path:
        original_filename = PurePosixPath(file_path.replace("\\", "/")).name
        _, ext = os.path.splitext(original_filename)
        if not ext:
            ext = ".pdf"
    else:
        ext = ".pdf"

    year = invoice_date.strftime("%Y") if invoice_date else "unknown"
    month = invoice_date.strftime("%m") if invoice_date else "01"
    doc_uuid = str(uuid.uuid4())
    account = normalize_utf8(account_id) or "unknown"

    return f"{source_system}/{year}/{month}/{account}/{doc_uuid}{ext}"


# =============================================================================
# Extract & Transform
# =============================================================================
def extract_invoices(cursor, table_name, batch_size):
    """
    Extract invoice rows from a legacy SQL Server table.
    Yields batches of rows.
    """
    query = f"""
        SELECT
            InvoiceID,
            AccountNumber,
            InvoiceDate,
            InvoiceNumber,
            InvoiceAmount,
            DueDate,
            BillingStart,
            BillingEnd,
            ServiceAddress,
            FilePath
        FROM [{table_name}]
        ORDER BY InvoiceID
    """
    cursor.execute(query)

    batch = []
    for row in cursor:
        batch.append(row)
        if len(batch) >= batch_size:
            yield batch
            batch = []
    if batch:
        yield batch


def extract_collection_letters(cursor, table_name, batch_size):
    """
    Extract collection letter rows from a legacy SQL Server table.
    Yields batches of rows.
    """
    query = f"""
        SELECT
            LetterID,
            AccountNumber,
            LetterDate,
            LetterType,
            BalanceDue,
            SentVia,
            FilePath
        FROM [{table_name}]
        ORDER BY LetterID
    """
    cursor.execute(query)

    batch = []
    for row in cursor:
        batch.append(row)
        if len(batch) >= batch_size:
            yield batch
            batch = []
    if batch:
        yield batch


def transform_invoice_row(row, source_system, table_name, env):
    """Transform a legacy invoice row to new schema format."""
    (
        invoice_id, account_number, invoice_date, invoice_number,
        invoice_amount, due_date, billing_start, billing_end,
        service_address, file_path
    ) = row

    s3_bucket = f"invoice-docs-{env}"
    s3_key = derive_s3_key(source_system, file_path, invoice_date, account_number)

    document = {
        "id": str(uuid.uuid4()),
        "document_kind": "invoice",
        "source_system": source_system,
        "account_id": normalize_utf8(account_number),
        "received_date": invoice_date,
        "s3_bucket": s3_bucket,
        "s3_key": s3_key,
        "s3_version_id": None,
        "file_size_bytes": None,
        "content_hash_sha256": None,
        "status": "active",
        "legacy_source_table": table_name,
        "legacy_source_id": invoice_id,
    }

    detail = {
        "id": str(uuid.uuid4()),
        "invoice_number": normalize_utf8(invoice_number),
        "invoice_date": invoice_date,
        "due_date": due_date,
        "amount_cents": money_to_cents(invoice_amount),
        "currency_code": "USD",
        "billing_period_start": billing_start,
        "billing_period_end": billing_end,
        "service_address": normalize_utf8(service_address),
    }

    return document, detail


def transform_collection_row(row, source_system, table_name, env):
    """Transform a legacy collection letter row to new schema format."""
    (
        letter_id, account_number, letter_date, letter_type,
        balance_due, sent_via, file_path
    ) = row

    s3_bucket = f"invoice-docs-{env}"
    s3_key = derive_s3_key(source_system, file_path, letter_date, account_number)

    document = {
        "id": str(uuid.uuid4()),
        "document_kind": "collection_letter",
        "source_system": source_system,
        "account_id": normalize_utf8(account_number),
        "received_date": letter_date,
        "s3_bucket": s3_bucket,
        "s3_key": s3_key,
        "s3_version_id": None,
        "file_size_bytes": None,
        "content_hash_sha256": None,
        "status": "active",
        "legacy_source_table": table_name,
        "legacy_source_id": letter_id,
    }

    detail = {
        "id": str(uuid.uuid4()),
        "letter_type": normalize_utf8(letter_type),
        "letter_date": letter_date,
        "balance_due_cents": money_to_cents(balance_due),
        "previous_invoice_id": None,
        "sent_via": normalize_utf8(sent_via),
    }

    return document, detail


# =============================================================================
# Load
# =============================================================================
def load_invoice_batch(pg_cursor, documents, details):
    """Insert a batch of invoice documents and details into Aurora.

    Uses INSERT ... ON CONFLICT ... RETURNING id to safely handle duplicates.
    If a document already exists, we look up its id so the detail row can
    still reference it (idempotent re-runs).
    """
    doc_sql = """
        INSERT INTO invoice_docs.documents (
            id, document_kind, source_system, account_id, received_date,
            s3_bucket, s3_key, s3_version_id, file_size_bytes,
            content_hash_sha256, status, legacy_source_table, legacy_source_id
        ) VALUES (
            %(id)s, %(document_kind)s, %(source_system)s, %(account_id)s,
            %(received_date)s, %(s3_bucket)s, %(s3_key)s, %(s3_version_id)s,
            %(file_size_bytes)s, %(content_hash_sha256)s, %(status)s,
            %(legacy_source_table)s, %(legacy_source_id)s
        )
        ON CONFLICT (legacy_source_table, legacy_source_id) DO UPDATE
            SET legacy_source_id = EXCLUDED.legacy_source_id
        RETURNING id
    """

    detail_sql = """
        INSERT INTO invoice_docs.invoice_details (
            id, document_id, invoice_number, invoice_date, due_date,
            amount_cents, currency_code, billing_period_start,
            billing_period_end, service_address
        ) VALUES (
            %(id)s, %(document_id)s, %(invoice_number)s, %(invoice_date)s,
            %(due_date)s, %(amount_cents)s, %(currency_code)s,
            %(billing_period_start)s, %(billing_period_end)s,
            %(service_address)s
        )
        ON CONFLICT (invoice_number) DO NOTHING
    """

    inserted = 0
    skipped = 0

    for doc, detail in zip(documents, details):
        pg_cursor.execute(doc_sql, doc)
        row = pg_cursor.fetchone()
        actual_doc_id = str(row[0]) if row else doc["id"]
        detail["document_id"] = actual_doc_id
        pg_cursor.execute(detail_sql, detail)
        if actual_doc_id == doc["id"]:
            inserted += 1
        else:
            skipped += 1

    return inserted, skipped


def load_collection_batch(pg_cursor, documents, details):
    """Insert a batch of collection letter documents and details into Aurora.

    Uses INSERT ... ON CONFLICT ... RETURNING id for idempotent re-runs.
    """
    doc_sql = """
        INSERT INTO invoice_docs.documents (
            id, document_kind, source_system, account_id, received_date,
            s3_bucket, s3_key, s3_version_id, file_size_bytes,
            content_hash_sha256, status, legacy_source_table, legacy_source_id
        ) VALUES (
            %(id)s, %(document_kind)s, %(source_system)s, %(account_id)s,
            %(received_date)s, %(s3_bucket)s, %(s3_key)s, %(s3_version_id)s,
            %(file_size_bytes)s, %(content_hash_sha256)s, %(status)s,
            %(legacy_source_table)s, %(legacy_source_id)s
        )
        ON CONFLICT (legacy_source_table, legacy_source_id) DO UPDATE
            SET legacy_source_id = EXCLUDED.legacy_source_id
        RETURNING id
    """

    detail_sql = """
        INSERT INTO invoice_docs.collection_letter_details (
            id, document_id, letter_type, letter_date, balance_due_cents,
            previous_invoice_id, sent_via
        ) VALUES (
            %(id)s, %(document_id)s, %(letter_type)s, %(letter_date)s,
            %(balance_due_cents)s, %(previous_invoice_id)s, %(sent_via)s
        )
        ON CONFLICT DO NOTHING
    """

    inserted = 0
    skipped = 0

    for doc, detail in zip(documents, details):
        pg_cursor.execute(doc_sql, doc)
        row = pg_cursor.fetchone()
        actual_doc_id = str(row[0]) if row else doc["id"]
        detail["document_id"] = actual_doc_id
        pg_cursor.execute(detail_sql, detail)
        if actual_doc_id == doc["id"]:
            inserted += 1
        else:
            skipped += 1

    return inserted, skipped


# =============================================================================
# Main ETL Pipeline
# =============================================================================
def run_etl(args, logger):
    """Run the ETL pipeline for a given source, year, and environment."""
    years = list(range(2015, 2025)) if args.year == "all" else [int(args.year)]

    total_inserted = 0
    total_skipped = 0
    total_errors = 0

    logger.info(
        "Starting ETL",
        extra={"extra_data": {
            "env": args.env,
            "source": args.source,
            "years": years,
            "dry_run": args.dry_run,
            "batch_size": args.batch_size,
            "document_kind": args.document_kind,
            "table_pattern": args.table_pattern,
        }},
    )

    if not args.dry_run:
        pg_conn = get_aurora_connection(args.env, args.region)
        pg_conn.autocommit = False

    sql_conn = get_sqlserver_connection(args.env, args.region)
    sql_cursor = sql_conn.cursor()

    try:
        for year in years:
            table_name = args.table_pattern.format(year=year)
            year_inserted = 0
            year_skipped = 0
            year_errors = 0
            row_count = 0

            logger.info(
                f"Processing {table_name}",
                extra={"extra_data": {"table": table_name, "year": year}},
            )

            try:
                if args.document_kind == "invoice":
                    batch_iter = extract_invoices(sql_cursor, table_name, args.batch_size)
                else:
                    batch_iter = extract_collection_letters(sql_cursor, table_name, args.batch_size)

                for batch in batch_iter:
                    documents = []
                    details = []

                    for row in batch:
                        try:
                            if args.document_kind == "invoice":
                                doc, detail = transform_invoice_row(
                                    row, args.source, table_name, args.env
                                )
                            else:
                                doc, detail = transform_collection_row(
                                    row, args.source, table_name, args.env
                                )
                            documents.append(doc)
                            details.append(detail)
                        except Exception as e:
                            year_errors += 1
                            logger.error(
                                f"Transform error: {e}",
                                extra={"extra_data": {"table": table_name}},
                            )

                    row_count += len(batch)

                    if not args.dry_run and documents:
                        try:
                            pg_cursor = pg_conn.cursor()
                            if args.document_kind == "invoice":
                                inserted, skipped = load_invoice_batch(
                                    pg_cursor, documents, details
                                )
                            else:
                                inserted, skipped = load_collection_batch(
                                    pg_cursor, documents, details
                                )
                            pg_conn.commit()
                            year_inserted += inserted
                            year_skipped += skipped
                        except Exception as e:
                            pg_conn.rollback()
                            year_errors += len(documents)
                            logger.error(
                                f"Load error: {e}",
                                extra={"extra_data": {"table": table_name}},
                            )

                    if row_count % 10000 == 0 and row_count > 0:
                        logger.info(
                            f"Progress: {row_count} rows processed",
                            extra={"extra_data": {
                                "table": table_name,
                                "rows_processed": row_count,
                            }},
                        )

            except pyodbc.ProgrammingError as e:
                logger.warning(
                    f"Table {table_name} not found, skipping: {e}",
                    extra={"extra_data": {"table": table_name}},
                )
                continue

            if args.dry_run:
                logger.info(
                    f"Dry run complete for {table_name}",
                    extra={"extra_data": {
                        "table": table_name,
                        "source_row_count": row_count,
                        "transform_errors": year_errors,
                    }},
                )
            else:
                logger.info(
                    f"Year {year} complete",
                    extra={"extra_data": {
                        "table": table_name,
                        "source_row_count": row_count,
                        "inserted": year_inserted,
                        "skipped_duplicates": year_skipped,
                        "errors": year_errors,
                    }},
                )

            total_inserted += year_inserted
            total_skipped += year_skipped
            total_errors += year_errors

    finally:
        sql_cursor.close()
        sql_conn.close()
        if not args.dry_run:
            pg_conn.close()

    logger.info(
        "ETL complete",
        extra={"extra_data": {
            "total_inserted": total_inserted,
            "total_skipped": total_skipped,
            "total_errors": total_errors,
        }},
    )

    return total_errors


def main():
    parser = argparse.ArgumentParser(
        description="Invoice Document Metadata ETL - Legacy SQL Server to Aurora PostgreSQL",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Migrate invoices from a billing system for year 2020 (dry run)
  python metadata_etl.py --env qa --source billing_system \\
      --table-pattern "Invoices_{year}" --document-kind invoice --year 2020 --dry-run

  # Migrate all years of collection letters
  python metadata_etl.py --env prod --source collections \\
      --table-pattern "CollectionLetters_{year}" --document-kind collection_letter --year all

  # Custom batch size
  python metadata_etl.py --env stage --source erp_system \\
      --table-pattern "ERPInvoices_{year}" --document-kind invoice --year 2023 --batch-size 500
        """,
    )

    parser.add_argument(
        "--env",
        required=True,
        choices=["qa", "stage", "prod"],
        help="Target environment",
    )
    parser.add_argument(
        "--source",
        required=True,
        help="Source system name (e.g., billing_system, collections). "
        "Used as the source_system value and S3 key prefix.",
    )
    parser.add_argument(
        "--table-pattern",
        required=True,
        help="Legacy table name pattern with {year} placeholder "
        '(e.g., "Invoices_{year}", "CollectionLetters_{year}")',
    )
    parser.add_argument(
        "--document-kind",
        required=True,
        choices=["invoice", "collection_letter"],
        help="Type of document being migrated",
    )
    parser.add_argument(
        "--year",
        required=True,
        help="Year to migrate (2015-2024) or 'all' for all years",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate and print counts without inserting into Aurora",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=1000,
        help="Number of rows per INSERT batch (default: 1000)",
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region (default: us-east-1)",
    )

    args = parser.parse_args()

    # Validate year
    if args.year != "all":
        try:
            year_val = int(args.year)
            if year_val < 2015 or year_val > 2024:
                parser.error("year must be between 2015 and 2024, or 'all'")
        except ValueError:
            parser.error("year must be an integer or 'all'")

    # Validate table pattern
    if "{year}" not in args.table_pattern:
        parser.error("table-pattern must contain {year} placeholder")

    logger = setup_logging(args.env)
    error_count = run_etl(args, logger)

    if error_count > 0:
        logger.error(f"ETL completed with {error_count} errors")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
