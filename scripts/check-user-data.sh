#!/usr/bin/env bash
# Render the host bootstrap template and syntax-check it.
#
# Usage: check-user-data.sh [TEMPLATE]
#   TEMPLATE defaults to modules/pds/user-data.sh.tftpl in this repository. A consumer can point
#   it at the copy `tofu init` fetched, e.g. .terraform/modules/pds/modules/pds/user-data.sh.tftpl
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
# The template is rendered by OpenTofu's own templatefile() in a throwaway root with no
# providers, so directives (%{ if }) render exactly as they do in the module, and a variable
# the template uses but this check does not pass is an error rather than a silent gap. Needs
# `tofu` on PATH; no credentials, no network.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="${1:-$HERE/../modules/pds/user-data.sh.tftpl}"
[ -f "$TPL" ] || { echo "missing $TPL" >&2; exit 1; }
TPL="$(cd "$(dirname "$TPL")" && pwd)/$(basename "$TPL")"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Render the template with the same variable names the module passes, and values shaped like
# real ones. $1 is swap_mb, $2 bootstrap_account (default false). Prints the rendered text.
render() {
  local swap_mb="$1" account="${2:-false}" dir="$WORK/render"
  rm -rf "$dir"; mkdir -p "$dir"
  cat > "$dir/main.tf" <<HCL
output "user_data" {
  value = templatefile("$TPL", {
    hostname              = "test.pds.example.com"
    handle                = "alice.test.pds.example.com"
    namespace             = "com.example.pds.test"
    environment           = "test"
    pds_image             = "ghcr.io/bluesky-social/pds@sha256:$(printf '0%.0s' $(seq 1 64))"
    contact_ssm_parameter = "/example/test/acme-contact-email"
    backup_bucket         = "example-identity-backup-000000000000"
    aws_region            = "us-east-1"
    swap_mb               = $swap_mb
    bootstrap_account     = $account
    account_ssm_prefix    = "/example/test"
  })
}
HCL
  (
    cd "$dir"
    tofu init -no-color -input=false >/dev/null
    tofu plan -no-color -input=false -out=render.tfplan >/dev/null
    tofu apply -no-color -input=false render.tfplan >/dev/null
    tofu output -raw user_data
  )
}

fail=0
check() { if ! eval "$2"; then echo "FAIL: $1" >&2; fail=1; fi; }

# swap_mb = 0 is the default render; 1024 exercises the optional swap block.
RENDERED="$WORK/user-data.sh"
SWAPPED="$WORK/user-data-swap.sh"
render 0 > "$RENDERED"
render 1024 > "$SWAPPED"
ACCOUNTED="$WORK/user-data-account.sh"
render 1024 true > "$ACCOUNTED"

bash -n "$RENDERED" || { echo "FAIL: rendered user-data (swap_mb=0) is not valid shell" >&2; exit 1; }
bash -n "$SWAPPED" || { echo "FAIL: rendered user-data (swap_mb=1024) is not valid shell" >&2; exit 1; }
bash -n "$ACCOUNTED" || { echo "FAIL: rendered user-data (bootstrap_account) is not valid shell" >&2; exit 1; }

# The account script is a quoted heredoc, which `bash -n` above only sees as text: parse it too.
ENSURE="$WORK/pds-ensure-account"
sed -n "/<<'ACCOUNTEOF'$/,/^ACCOUNTEOF$/p" "$ACCOUNTED" | sed '1d;$d' > "$ENSURE"
[ -s "$ENSURE" ] || { echo "FAIL: pds-ensure-account is missing from the bootstrap_account render" >&2; exit 1; }
bash -n "$ENSURE" || { echo "FAIL: pds-ensure-account is not valid shell" >&2; exit 1; }
if command -v shellcheck >/dev/null; then
  shellcheck "$ENSURE" || { echo "FAIL: pds-ensure-account has shellcheck findings" >&2; exit 1; }
fi

# Cheap structural assertions about things that have actually broken.
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
check "swap_mb = 0 renders no swap step" \
  "! grep -q 'swapon' '$RENDERED'"
check "bootstrap_account = false renders no account step" \
  "! grep -q 'pds-ensure-account' '$RENDERED'"
check "bootstrap_account publishes the PDS port on loopback only" \
  "grep -q '127.0.0.1:3000:3000' '$ACCOUNTED' && ! grep -qE '\"3000:3000\"' '$ACCOUNTED'"
check "the account step runs for the handle with the /<prefix>/<env> SSM prefix" \
  "grep -qF '/usr/local/bin/pds-ensure-account \"alice.test.pds.example.com\" \"/example/test\"' '$ACCOUNTED'"
check "an existing handle exits before anything is created" \
  "[ \$(grep -n 'resolveHandle' '$ENSURE' | cut -d: -f1) -lt \$(grep -n 'createInviteCode' '$ENSURE' | cut -d: -f1) ]"
check "the account password is stored before the app password is minted" \
  "[ \$(grep -n 'account-password' '$ENSURE' | head -1 | cut -d: -f1) -lt \$(grep -n 'createAppPassword' '$ENSURE' | cut -d: -f1) ]"
check "swap_mb = 1024 creates and enables a swap file" \
  "grep -q '^SWAP_MB=1024$' '$SWAPPED' && grep -q 'swapon' '$SWAPPED'"

[ "$fail" -eq 0 ] || exit 1
echo "user-data renders, parses as shell, and holds its structural invariants"
