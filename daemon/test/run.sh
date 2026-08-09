#!/usr/bin/env bash
# Run the whole vault-bridge suite. Exits non-zero if any test fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test_*.sh; do
  printf '\n=== %s ===\n' "$(basename "$t")"
  bash "$t" || rc=1
done
printf '\n%s\n' "$([ $rc -eq 0 ] && echo 'ALL SUITES PASSED' || echo 'FAILURES PRESENT')"
exit $rc
