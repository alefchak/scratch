#!/usr/bin/env bash
# Apply Terragrunt units in dependency order.
#
# For each unit:
#   - If none of its dependencies changed their outputs during this run, apply
#     the saved (reviewed) plan from the plan stage.
#   - If any dependency's outputs changed (including a brand-new dependency whose
#     outputs were mocked at plan time), the saved plan was built from stale
#     inputs, so re-plan against the real outputs and apply that instead.
#   - If this unit's own plan changes its outputs, mark it as changed so the
#     effect cascades to everything downstream.
#
# Env vars:
#   PLAN_DIR       saved binary plans          (default: ./plans)
#   PLAN_JSON_DIR  saved JSON plans            (default: ./plans-json)
#   REPLAN_DIR     where re-plans are written  (default: ./replans)
#   REPLAN_POLICY  apply | fail                (default: apply)
#                    apply: re-plan and apply automatically
#                    fail:  stop at the first unit that needs a re-plan; re-run
#                           the pipeline to get a reviewable plan for it
#
# Requires: bash 4+, terragrunt, terraform/tofu, jq, GNU coreutils (realpath).
set -euo pipefail

ROOT="$PWD"
PLAN_DIR="${PLAN_DIR:-$ROOT/plans}"
PLAN_JSON_DIR="${PLAN_JSON_DIR:-$ROOT/plans-json}"
REPLAN_DIR="${REPLAN_DIR:-$ROOT/replans}"
REPLAN_POLICY="${REPLAN_POLICY:-apply}"

export TG_NON_INTERACTIVE=true

# True if the plan changes (creates/updates/deletes) any root module output.
outputs_change() {
  jq -e '[(.output_changes // {}) | .[] | .actions[]] | any(. != "no-op")' "$1" > /dev/null
}

# Normalize a path to be relative to the repo root.
norm() { realpath -m --relative-to="$ROOT" "$1"; }

# Resolve a dependency path as reported by `terragrunt find` for a given unit.
# Handles "../vpc" (relative to the unit), "live/prod/vpc" (relative to root)
# and absolute paths.
resolve_dep() {
  local unit="$1" dep="$2"
  case "$dep" in
    /*) norm "$dep" ;;
    .*) norm "$ROOT/$unit/$dep" ;;
    *)  norm "$ROOT/$dep" ;;
  esac
}

declare -A changed=()
replanned=()
applied=()

units_json="$PLAN_DIR/units.json"
if [[ ! -f "$units_json" ]]; then
  terragrunt find --dag --dependencies --json > "$units_json"
fi

while IFS= read -r unit; do
  path=$(norm "$ROOT/$(jq -r '.path' <<< "$unit")")
  saved="$PLAN_DIR/$path/tfplan.tfplan"
  saved_json="$PLAN_JSON_DIR/$path/tfplan.json"

  # Did any dependency change its outputs earlier in this run?
  stale_because=""
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    dep=$(resolve_dep "$path" "$dep")
    if [[ -n "${changed[$dep]:-}" ]]; then
      stale_because="$dep"
      break
    fi
  done < <(jq -r '.dependencies // [] | .[]' <<< "$unit")

  if [[ -z "$stale_because" ]]; then
    if [[ ! -f "$saved" ]]; then
      echo "== $path: no saved plan and no upstream changes, skipping"
      continue
    fi
    echo "== $path: applying saved plan"
    (cd "$ROOT/$path" && terragrunt run -- apply "$saved")
    plan_json="$saved_json"
    applied+=("$path")
  else
    echo "== $path: outputs of $stale_because changed, saved plan is stale"
    if [[ "$REPLAN_POLICY" == "fail" ]]; then
      echo "REPLAN_POLICY=fail: stopping before $path." >&2
      echo "Upstream units are applied; re-run the pipeline to plan $path against real outputs." >&2
      exit 1
    fi
    mkdir -p "$REPLAN_DIR/$path"
    replan="$REPLAN_DIR/$path/tfplan.tfplan"
    plan_json="$REPLAN_DIR/$path/tfplan.json"
    (
      cd "$ROOT/$path"
      terragrunt run -- plan -out="$replan"
      terragrunt run -- show -json "$replan" > "$plan_json"
      terragrunt run -- apply "$replan"
    )
    replanned+=("$path")
  fi

  if [[ -f "$plan_json" ]] && outputs_change "$plan_json"; then
    changed[$path]=1
  fi
done < <(jq -c '.[] | select(.type == "unit")' "$units_json")

echo
echo "Applied from saved plan: ${#applied[@]}"
for u in "${applied[@]}"; do echo "  - $u"; done
echo "Re-planned and applied:  ${#replanned[@]}"
for u in "${replanned[@]}"; do echo "  - $u  (plan saved in $REPLAN_DIR/$u/)"; done
