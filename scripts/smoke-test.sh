#!/usr/bin/env bash
set -euo pipefail

# Invoice Document Storage - Smoke Test Script
# Usage: bash scripts/smoke-test.sh <env>
# Example: bash scripts/smoke-test.sh qa

ENV="${1:-}"

if [[ -z "$ENV" ]] || [[ ! "$ENV" =~ ^(qa|stage|prod)$ ]]; then
    echo "Usage: $0 <env>"
    echo "  env: qa | stage | prod"
    exit 1
fi

BUCKET="invoice-docs-${ENV}"
SMOKE_KEY="smoke-test/smoke-test-$(date +%s).txt"
PASSED=0
FAILED=0

pass() {
    echo "  PASS: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo "  FAIL: $1"
    FAILED=$((FAILED + 1))
}

echo "=== Invoice Document Storage Smoke Test ==="
echo "Environment: ${ENV}"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ---------------------------------------------------------------------------
# Test 1: S3 Write (SSE-KMS)
# ---------------------------------------------------------------------------
echo "[1/4] Testing S3 write with SSE-KMS..."
if aws s3 cp - "s3://${BUCKET}/${SMOKE_KEY}" \
    --sse aws:kms \
    <<< "smoke-test-$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null; then
    pass "S3 write with SSE-KMS succeeded"
else
    fail "S3 write with SSE-KMS failed"
fi

# ---------------------------------------------------------------------------
# Test 2: Secrets Manager - Aurora credentials
# ---------------------------------------------------------------------------
echo "[2/4] Testing Secrets Manager access..."

# Find the Aurora master secret ARN
SECRET_LIST=$(aws secretsmanager list-secrets \
    --filters Key=name,Values="rds!cluster-" \
    --query "SecretList[?contains(Name, '${ENV}') || contains(Description, '${ENV}')].ARN" \
    --output text 2>/dev/null || true)

if [[ -n "$SECRET_LIST" ]]; then
    SECRET_ARN=$(echo "$SECRET_LIST" | head -1)
    SECRET_VALUE=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_ARN" \
        --query SecretString --output text 2>/dev/null || true)
    if [[ -n "$SECRET_VALUE" ]] && echo "$SECRET_VALUE" | jq -e '.username' > /dev/null 2>&1; then
        pass "Secrets Manager returned valid credentials"
    else
        fail "Secrets Manager returned invalid credentials format"
    fi
else
    fail "No Aurora secret found for environment ${ENV}"
fi

# ---------------------------------------------------------------------------
# Test 3: Aurora PostgreSQL connectivity
# ---------------------------------------------------------------------------
echo "[3/4] Testing Aurora PostgreSQL connectivity..."

if [[ -n "${SECRET_VALUE:-}" ]]; then
    DB_HOST=$(echo "$SECRET_VALUE" | jq -r '.host')
    DB_USER=$(echo "$SECRET_VALUE" | jq -r '.username')
    DB_PASS=$(echo "$SECRET_VALUE" | jq -r '.password')
    DB_PORT=$(echo "$SECRET_VALUE" | jq -r '.port // 5432')

    RESULT=$(PGPASSWORD="$DB_PASS" psql \
        -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres \
        -t -A -c "SELECT 1" 2>/dev/null || true)

    if [[ "$RESULT" == "1" ]]; then
        pass "Aurora PostgreSQL SELECT 1 succeeded"
    else
        fail "Aurora PostgreSQL SELECT 1 failed"
    fi
else
    fail "Skipping Aurora test (no credentials available)"
fi

# ---------------------------------------------------------------------------
# Test 4: CloudWatch Alarms
# ---------------------------------------------------------------------------
echo "[4/4] Testing CloudWatch alarms exist..."

ALARM_COUNT=$(aws cloudwatch describe-alarms \
    --alarm-name-prefix "aurora-cpu-high-${ENV}" \
    --query 'length(MetricAlarms)' --output text 2>/dev/null || echo "0")

ALARM_STATES=$(aws cloudwatch describe-alarms \
    --alarm-name-prefix "" \
    --query "MetricAlarms[?contains(AlarmName, '${ENV}')].{Name: AlarmName, State: StateValue}" \
    --output table 2>/dev/null || true)

if [[ "$ALARM_COUNT" -ge 1 ]]; then
    pass "CloudWatch alarms exist for ${ENV}"

    # Check if any alarms are in ALARM state
    ALARM_FIRING=$(aws cloudwatch describe-alarms \
        --state-value ALARM \
        --query "MetricAlarms[?contains(AlarmName, '${ENV}')].AlarmName" \
        --output text 2>/dev/null || true)

    if [[ -z "$ALARM_FIRING" ]]; then
        pass "No alarms are in ALARM state"
    else
        echo "  WARNING: Alarms in ALARM state: ${ALARM_FIRING}"
    fi
else
    fail "No CloudWatch alarms found for ${ENV}"
fi

# ---------------------------------------------------------------------------
# Cleanup: Remove smoke test S3 object
# ---------------------------------------------------------------------------
echo ""
echo "Cleaning up smoke test object..."
aws s3 rm "s3://${BUCKET}/${SMOKE_KEY}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"
echo ""

if [[ "$FAILED" -gt 0 ]]; then
    echo "SMOKE TEST FAILED"
    exit 1
else
    echo "SMOKE TEST PASSED"
    exit 0
fi
