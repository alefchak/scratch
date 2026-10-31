# Terragrunt saved plans with automatic re-planning

Fixes two failures when applying saved Terragrunt plans in CI:

1. **Mock outputs**: a unit was planned with `mock_outputs` because its dependency
   didn't exist yet, so the saved plan contains mock values.
2. **Changed outputs**: a dependency's outputs change when it applies, so the
   downstream unit's saved plan was built from the old values.

Both are the same problem: a downstream plan was built from inputs that are no
longer true by the time it applies. Terraform refuses to apply a saved plan
whose variables don't match.

## How it works

**Plan stage** (`ci/tg-plan.sh`): runs `run --all plan` and saves, per unit, the
binary plan (`plans/`) and a JSON plan (`plans-json/`), plus the dependency graph
(`plans/units.json`).

**Apply stage** (`ci/tg-apply.sh`): walks units in dependency order.

| Situation | Action |
|---|---|
| No dependency changed outputs in this run | Apply the saved, reviewed plan |
| A dependency changed outputs (incl. a new dependency that was mocked) | Re-plan against real outputs, then apply |
| This unit's plan changes its own outputs | Mark it changed so downstream units re-plan |

Output changes are read from the plan JSON's `output_changes` block. A new unit
shows its outputs as `create`, and a changed output as `update`, so mocks need no
special handling.

## Dependency config

Keep mocks limited to planning so they can never reach an apply:

```hcl
dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id     = "mock-vpc-id"
    subnet_ids = ["mock-subnet"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]

  # If the dependency exists but is missing a newly added output, mock only the
  # missing keys instead of every output.
  mock_outputs_merge_strategy_with_state = "shallow"
}
```

## Choosing a re-plan policy

Re-planned units are applied from a plan nobody reviewed. Set `REPLAN_POLICY`
per environment:

- `apply` (default): re-plan and apply automatically. Re-plans are saved under
  `replans/` as job artifacts so you can review them afterwards.
- `fail`: stop before the first unit that needs a re-plan. Everything upstream is
  already applied, so re-running the pipeline produces a correct, reviewable plan
  for the rest. A good fit for prod.

```yaml
apply:prod:
  extends: apply
  variables:
    REPLAN_POLICY: "fail"
```

## Notes

- Units are applied one at a time, in order. `run --all` would parallelize
  independent units; for most repos the difference is small.
- If you plan with `--filter`, units with no saved plan are skipped unless an
  upstream change makes them stale, in which case they're re-planned and applied.
- The apply job must run on the same commit as the plan job (it does, via `needs`)
  so the provider lock file and module sources match the saved plans.
