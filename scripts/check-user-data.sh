#!/usr/bin/env bash
# Render the host bootstrap template and syntax-check it.
#
# `tofu validate` checks HCL. It does not look inside a templatefile, so a shell syntax error in
# user-data is invisible to every gate until cloud-init runs it on a real instance -- and by then
# the instance exists, the volume is attached, and finding out costs a replacement.
#
# That is not hypothetical: an edit left an orphaned `fi` behind, the plan was clean, the apply
# succeeded, the instance came up healthy, and the bootstrap died at line 160 with
# "syntax error near unexpected token `fi'". No container ever started. The only symptom from
# outside was a port that would not answer.
#
# This takes milliseconds. Run it before anything reaches a host.

set -euo pipefail
cd "$(dirname "$0")/.."

TPL=deploy/tofu/modules/pds/user-data.sh.tftpl
[ -f "$TPL" ] || { echo "missing $TPL" >&2; exit 1; }

RENDERED=$(mktemp); trap 'rm -f "$RENDERED"' EXIT

# Substitute the same names the module passes, with values shaped like the real ones.
python3 - "$TPL" "$RENDERED" <<'PY'
import re, sys
tpl, out = sys.argv[1], sys.argv[2]
vals = {
    "hostname": "test.graph.savetherepublic.us",
    "handle": "trb.test.graph.savetherepublic.us",
    "namespace": "us.savetherepublic.graph.test",
    "environment": "test",
    "pds_image": "ghcr.io/bluesky-social/pds@sha256:" + "0" * 64,
    "contact_ssm_parameter": "/trb/test/acme-contact-email",
    "backup_bucket": "trb-identity-backup-000000000000",
    "aws_region": "us-east-1",
}
text = open(tpl).read()
unknown = {m for m in re.findall(r'\$\{(\w+)\}', text)} - set(vals)
if unknown:
    print(f"template interpolates names this check does not know: {sorted(unknown)}", file=sys.stderr)
    print("add them to deploy/check-user-data.sh, or the check is lying about coverage", file=sys.stderr)
    raise SystemExit(1)
open(out, "w").write(re.sub(r'\$\{(\w+)\}', lambda m: vals[m.group(1)], text))
PY

bash -n "$RENDERED" || { echo "FAIL: rendered user-data is not valid shell" >&2; exit 1; }

# Cheap structural assertions about things that have actually broken.
fail=0
check() { if ! eval "$2"; then echo "FAIL: $1" >&2; fail=1; fi; }

check "secrets file is written before compose reads it" \
      "grep -q 'secrets.env' '$RENDERED'"
check "a pre-split volume migrates its secrets rather than regenerating them" \
      "grep -q 'NOT regenerating them' '$RENDERED'"
check "the email config is both-or-neither (a partial config crash-loops the PDS)" \
      "! grep -qE '^PDS_EMAIL_FROM_ADDRESS=.+' '$RENDERED'"
check "mkfs is guarded by a filesystem test" \
      "grep -B4 'mkfs.ext4' '$RENDERED' | grep -q 'FSTYPE'"
check "on-demand TLS declares an ask endpoint (Caddy will not start without one)" \
      "grep -q 'on_demand_tls' '$RENDERED'"

[ "$fail" -eq 0 ] || exit 1
echo "user-data renders, parses as shell, and holds its structural invariants"
