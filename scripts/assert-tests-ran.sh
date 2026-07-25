#!/usr/bin/env bash
#
# `** TEST SUCCEEDED **` proves nothing.
#
# xcodebuild prints it just as happily after running *zero* tests — which is
# exactly what happens when a scheme's test action is empty, or when a new test
# file exists on disk but `tuist generate` hasn't expanded the source glob into
# the .xcodeproj yet. That failure mode already cost this repo two "green" runs
# of a suite that never executed.
#
# So the pass condition in CI is not xcodebuild's exit code — it's this: every
# test bundle we expect actually ran, and none of their tests failed.
#
# Usage: scripts/assert-tests-ran.sh <result.xcresult> [required-bundle ...]
set -euo pipefail

BUNDLE=${1:?usage: assert-tests-ran.sh <result.xcresult> [required-bundle ...]}
shift
REQUIRED=("$@")

if [ ! -e "$BUNDLE" ]; then
    echo "::error::no result bundle at $BUNDLE — the test action never produced one"
    exit 1
fi

SUMMARY=$(xcrun xcresulttool get test-results summary --path "$BUNDLE" --format json)
TESTS=$(xcrun xcresulttool get test-results tests --path "$BUNDLE" --format json)

read -r RESULT TOTAL PASSED FAILED SKIPPED <<<"$(
    printf '%s' "$SUMMARY" |
        jq -r '[.result, .totalTestCount, .passedTests, .failedTests, .skippedTests] | @tsv'
)"

echo "result=$RESULT total=$TOTAL passed=$PASSED failed=$FAILED skipped=$SKIPPED"

# Per-bundle counts: a bundle that vanished from the scheme reports nothing at
# all, so it has to be checked by name rather than by a total.
RAN=$(printf '%s' "$TESTS" | jq -r '
    .testNodes[0].children[]?
    | "\(.name)\t\([recurse(.children[]?) | select(.nodeType == "Test Case")] | length)"')
printf '%s\n' "$RAN" | sed 's/^/  /'

STATUS=0

if [ "$TOTAL" -eq 0 ]; then
    echo "::error::the suite executed zero tests."
    echo "         Usually a stale project: run 'tuist generate' so test files join the target."
    STATUS=1
fi

for bundle in ${REQUIRED+"${REQUIRED[@]}"}; do
    count=$(printf '%s\n' "$RAN" | awk -F'\t' -v b="$bundle" '$1 == b { print $2 }')
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        echo "::error::$bundle ran no tests — it dropped out of the scheme's test action."
        STATUS=1
    fi
done

if [ "$FAILED" -ne 0 ] || [ "$RESULT" != "Passed" ]; then
    echo "::error::$FAILED test(s) failed (result: $RESULT)"
    printf '%s' "$SUMMARY" |
        jq -r '.testFailures[]? | "  ✗ \(.testName) — \(.failureText // "no message")"'
    STATUS=1
fi

exit $STATUS
