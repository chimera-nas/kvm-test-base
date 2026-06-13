#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chimera-NAS Project Contributors
#
# SPDX-License-Identifier: Unlicense
#
# Run one LTP scenario group against the harness-mounted share at /mnt and exit
# non-zero iff any non-skipped test FAILED or was BROKEN.
#
# LTP's old runltp was removed upstream in favour of kirk; kirk runs the LTP
# framework (resolved via LTPROOT) on the local host shell.  kirk's own exit
# status only reflects framework errors -- it returns 0 even when tests fail --
# so the pass/fail verdict comes from the "stats" block of its JSON report.
# The per-group /opt/ltp-skip/<group>.skip allowlist lists cases that fail or
# break for reasons intrinsic to NFS, so a non-zero exit here is a real server
# regression.
#
# Usage: ltp-run.sh <group>   (e.g. ltp-run.sh syscalls)
set -u

grp="$1"
skip="/opt/ltp-skip/${grp}.skip"
json="/tmp/ltp_${grp}.json"
work="/mnt/ltp"

rm -rf "$work"
mkdir -p "$work"

skip_arg=""
[ -f "$skip" ] && skip_arg="-S $skip"

# Tests chdir into a unique subdir of -d (the NFS mount), so file I/O lands on
# the share under test.  testcases/bin on PATH for tests that exec LTP helpers.
LTPROOT=/opt/ltp PATH="/opt/ltp/testcases/bin:$PATH" \
    python3 /opt/kirk/kirk -f "$grp" -d "$work" $skip_arg -o "$json"

# Verdict from the JSON report (kirk's own exit status ignores test failures).
# On failure also list the offending test FQNs so the CI log is actionable and
# the per-group skip file can be seeded directly from it.
python3 - "$json" "$grp" <<'PY'
import json, sys
path, grp = sys.argv[1], sys.argv[2]
try:
    report = json.load(open(path))
    stats = report["stats"]
except Exception as exc:
    print("LTP %s verdict: no/invalid JSON report (%s)" % (grp, exc))
    sys.exit(1)
print(("LTP %s verdict: " % grp) +
      "passed=%(passed)s failed=%(failed)s broken=%(broken)s "
      "skipped=%(skipped)s warnings=%(warnings)s" % stats)
bad = [r["test_fqn"] for r in report.get("results", [])
       if r.get("status") in ("fail", "brok")]
if bad:
    print("LTP %s failed/broken tests (skip-file candidates):" % grp)
    for name in bad:
        print("  %s" % name)
sys.exit(1 if stats["failed"] or stats["broken"] else 0)
PY
