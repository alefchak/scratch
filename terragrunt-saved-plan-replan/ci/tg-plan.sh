#!/usr/bin/env bash
# Plan every Terragrunt unit and save binary + JSON plans for the apply stage.
#
# Output (all paths mirror the unit tree):
#   plans/<unit>/tfplan.tfplan     binary plan, applied as-is when still valid
#   plans-json/<unit>/tfplan.json  JSON plan, used to detect output changes
#   plans/units.json               units in dependency order, with dependency edges
set -euo pipefail

ROOT="$PWD"
PLAN_DIR="${PLAN_DIR:-$ROOT/plans}"
PLAN_JSON_DIR="${PLAN_JSON_DIR:-$ROOT/plans-json}"

export TG_NON_INTERACTIVE=true

rm -rf "$PLAN_DIR" "$PLAN_JSON_DIR"

terragrunt run --all \
  --out-dir "$PLAN_DIR" \
  --json-out-dir "$PLAN_JSON_DIR" \
  -- plan

# Record the dependency graph at plan time so the apply stage walks the same order.
terragrunt find --dag --dependencies --json > "$PLAN_DIR/units.json"

# Informational: which units will change their outputs. Anything downstream of
# these will be re-planned in the apply stage.
echo
echo "Units whose outputs will change (downstream units will be re-planned at apply):"
found=false
while IFS= read -r f; do
  if jq -e '[(.output_changes // {}) | .[] | .actions[]] | any(. != "no-op")' "$f" > /dev/null; then
    unit="${f#"$PLAN_JSON_DIR"/}"
    echo "  - ${unit%/tfplan.json}"
    found=true
  fi
done < <(find "$PLAN_JSON_DIR" -name tfplan.json | sort)
$found || echo "  (none)"
