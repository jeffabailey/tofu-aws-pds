#!/usr/bin/env bash
# C-P7, mechanism three: no automated trigger may reach a destroy.
#
# ADR-013 §4 enforces this four times, because once is a convention. This is the structural
# check -- it catches a future edit that reintroduces a destroy path, after the reviewer who
# knew why it was forbidden has moved on.
#
# THIS SCRIPT LIVES OUTSIDE .github/ ON PURPOSE. The patterns it searches for are themselves
# text containing the word "destroy"; keeping them in a workflow file under .github/ meant the
# guard matched its own source and failed on every run. A check that always fails gets disabled,
# and a disabled check protects nothing.

set -euo pipefail
cd "$(dirname "$0")/.."

status=0

scan() {
  local label="$1" pattern="$2" dir="$3"
  local hits
  if hits=$(grep -rnE "$pattern" "$dir" 2>/dev/null); then
    echo "FAIL: $label"
    echo "$hits" | sed 's/^/    /'
    status=1
  fi
}

# A destroy invocation, in any of the forms that reach one.
scan "a destroy command appears under $1" \
     '(tofu|terraform)[[:space:]]+destroy|[[:space:]]-destroy([[:space:]]|$)' \
     "${1:-.github}"

# `-auto-approve` on a fresh plan is the other way to get there: apply must run a SAVED PLAN
# FILE, so that what is applied is what a human read. `tofu apply -auto-approve tfplan` is fine;
# `tofu apply -auto-approve` with no plan file is not.
if hits=$(grep -rnE '(tofu|terraform)[[:space:]]+apply[^|]*-auto-approve[[:space:]]*($|\|)' "${1:-.github}" 2>/dev/null); then
  echo "FAIL: apply -auto-approve without a saved plan file"
  echo "$hits" | sed 's/^/    /'
  echo "    Apply must run a saved plan, or it applies whatever the world looks like now,"
  echo "    which is not what any reviewer approved."
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "no destroy path under ${1:-.github}/ -- teardown remains a human act"
else
  echo
  echo "C-P7: teardown is a human act from a laptop, with human credentials, preceded by a"
  echo "commit that removes prevent_destroy. The awkwardness is the point."
fi

exit "$status"
