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
console="/tmp/ltp_${grp}.console"
work="/mnt/ltp"

rm -rf "$work"
mkdir -p "$work"

skip_arg=""
[ -f "$skip" ] && skip_arg="-S $skip"

# Tests chdir into a unique subdir of -d (the NFS mount), so file I/O lands on
# the share under test.  testcases/bin on PATH for tests that exec LTP helpers.
# Tee kirk's output: it stays on the console (serial log) and is also captured so
# the verdict can fall back to kirk's printed summary if the JSON report is
# unusable (see below).
LTPROOT=/opt/ltp PATH="/opt/ltp/testcases/bin:$PATH" \
    python3 /opt/kirk/kirk -f "$grp" -d "$work" $skip_arg -o "$json" 2>&1 | tee "$console"

# Verdict.  Primary source is the JSON report's "stats" (kirk's own exit status
# ignores test failures).  kirk has been observed to print a complete TEST
# SUMMARY but leave the JSON report empty when a test emits output it cannot
# serialise, so when the JSON is missing/unreadable we fall back to parsing the
# numbers out of kirk's console summary rather than failing opaquely.
python3 - "$json" "$console" "$grp" <<'PY'
import json, re, sys
jsonpath, consolepath, grp = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    report = json.load(open(jsonpath))
    stats = report["stats"]
    print(("LTP %s verdict (json): " % grp) +
          "passed=%(passed)s failed=%(failed)s broken=%(broken)s "
          "skipped=%(skipped)s warnings=%(warnings)s" % stats)
    bad = [r["test_fqn"] for r in report.get("results", [])
           if r.get("status") in ("fail", "brok")]
    if bad:
        print("LTP %s failed/broken tests (skip-file candidates):" % grp)
        for name in bad:
            print("  %s" % name)
    sys.exit(1 if stats["failed"] or stats["broken"] else 0)
except Exception as exc:
    # Fallback: parse kirk's printed TEST SUMMARY.
    text = open(consolepath, errors="replace").read()
    mf = re.search(r"Failed:\s+(\d+)", text)
    mb = re.search(r"Broken:\s+(\d+)", text)
    if mf and mb:
        failed, broken = int(mf.group(1)), int(mb.group(1))
        print("LTP %s verdict (console fallback; JSON unreadable: %s): "
              "failed=%d broken=%d" % (grp, exc, failed, broken))
        fl = re.search(r"Failures:\n((?:\s+\S.*\n)+)", text)
        if fl:
            print(fl.group(1).rstrip())
        sys.exit(1 if failed or broken else 0)
    print("LTP %s verdict: no usable JSON report and no parseable console "
          "summary (%s)" % (grp, exc))
    sys.exit(1)
PY
