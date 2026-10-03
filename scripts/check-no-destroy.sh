#!/usr/bin/env bash
# No automated trigger may reach a destroy.
#
# Usage: check-no-destroy.sh [DIR]     (DIR defaults to .github, relative to the CWD)
#
# This is the structural check: it catches a future edit that reintroduces a destroy path into a
# workflow, after the reviewer who knew why it was forbidden has moved on. It flags:
#   - any `tofu destroy` / `terraform destroy` / `-destroy` invocation;
#   - `apply -auto-approve` WITHOUT a saved plan file, which applies whatever the world looks
#     like now rather than what a human reviewed.
#
# THIS SCRIPT LIVES OUTSIDE .github/ ON PURPOSE. The patterns it searches for are themselves
# text containing the word "destroy"; keeping them in a workflow file under .github/ meant the
# guard matched its own source and failed on every run. A check that always fails gets disabled,
# and a disabled check protects nothing.
#
# Consumers: call it from CI against your own workflow directory, e.g.
#   .terraform/modules/pds/scripts/check-no-destroy.sh .github
# or vendor a copy at a pinned module tag.

set -euo pipefail

TARGET="${1:-.github}"
[ -d "$TARGET" ] || { echo "check-no-destroy: no such directory: $TARGET" >&2; exit 2; }

status=0

indent() { while IFS= read -r line; do printf '    %s\n' "$line"; done; }

scan() {
  local label="$1" pattern="$2" dir="$3"
  local hits
  if hits=$(grep -rnE "$pattern" "$dir" 2>/dev/null); then
    echo "FAIL: $label"
    indent <<<"$hits"
    status=1
  fi
}

# A destroy invocation, in any of the forms that reach one.
scan "a destroy command appears under $TARGET" \
  '(tofu|terraform)[[:space:]]+destroy|[[:space:]]-destroy([[:space:]]|$)' \
  "$TARGET"

# `-auto-approve` on a fresh plan is the other way to get there: apply must run a SAVED PLAN
# FILE, so that what is applied is what a human read. `tofu apply -auto-approve tfplan` is fine;
# `tofu apply -auto-approve` with no plan file is not.
if hits=$(grep -rnE '(tofu|terraform)[[:space:]]+apply[^|]*-auto-approve[[:space:]]*($|\|)' "$TARGET" 2>/dev/null); then
  echo "FAIL: apply -auto-approve without a saved plan file"
  indent <<<"$hits"
  echo "    Apply must run a saved plan, or it applies whatever the world looks like now,"
  echo "    which is not what any reviewer approved."
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "no destroy path under $TARGET/ -- teardown remains a human act"
else
  echo
  echo "Teardown is a human act from a laptop, with human credentials, preceded by a commit"
  echo "that removes prevent_destroy. The awkwardness is the point."
fi

exit "$status"
