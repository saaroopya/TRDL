#!/usr/bin/env bash
# End-to-end smoke tests for TRDL
set -euo pipefail

URL="${TRDL_URL:?Set TRDL_URL to the service endpoint (e.g. http://1.2.3.4)}"
PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    ((FAIL++))
  fi
}

# Test 1: GET / returns 42
body=$(curl -sf "${URL}/")
check "GET / returns 42" "42" "$body"

# Test 2: GET / returns 200
status=$(curl -so /dev/null -w '%{http_code}' "${URL}/")
check "GET / returns HTTP 200" "200" "$status"

# Test 3: GET /healthz returns 200
status=$(curl -so /dev/null -w '%{http_code}' "${URL}/healthz")
check "GET /healthz returns HTTP 200" "200" "$status"

# Test 4: GET /readyz returns 200
status=$(curl -so /dev/null -w '%{http_code}' "${URL}/readyz")
check "GET /readyz returns HTTP 200" "200" "$status"

# Test 5: GET /nonexistent returns 404
status=$(curl -so /dev/null -w '%{http_code}' "${URL}/nonexistent")
check "GET /nonexistent returns HTTP 404" "404" "$status"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
