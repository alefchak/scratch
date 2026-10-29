# Terragrunt mock outputs for a not-yet-applied output

How to plan a module that reads a **new** output from a dependency before that
output has been applied.

The case it's for: you add an output to a dependency module and reference it
from the module that uses it. You haven't applied the dependency yet, so the
output isn't in its state. Planning the using module fails with an error that
the output doesn't exist, and adding `mock_outputs` doesn't change the error.

## Why the mocks are ignored

Mock outputs are a fallback, not an override. Terragrunt uses them only when
the dependency returns **no outputs at all**, i.e. it has never been applied.

If the dependency already has state with outputs, Terragrunt reads the real
outputs and ignores `mock_outputs` entirely (the default merge strategy is
`no_merge`). Your new output isn't in that state yet, so the lookup fails as if
you'd never added a mock.

## The fix

[`terragrunt.hcl`](terragrunt.hcl) shows the dependency block. The key line
tells Terragrunt to merge the mocks with the real outputs:

```hcl
dependency "foo" {
  config_path = "../foo"

  mock_outputs = {
    new_output = "mock-value"
  }

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}
```

| Strategy | Behavior |
|---|---|
| `no_merge` (default) | Real outputs if any exist, otherwise mocks. Never mixes them. |
| `shallow` | Real outputs win; top-level keys missing from state come from the mocks. |
| `deep_map_only` | Like `shallow`, but also merges nested maps key by key. |

Older Terragrunt versions use `mock_outputs_merge_with_state = true` instead,
which is deprecated in newer releases.

## If it still fails

- **Allowed commands.** Mocks only apply to the commands listed in
  `mock_outputs_allowed_terraform_commands`. Running `apply` (or
  `run --all apply`) with `apply` missing from that list skips the mocks and
  errors.
- **Stale cache.** Delete `.terragrunt-cache` in both modules and try again.
- **Run-all ordering.** `run --all plan` only plans the dependency, it doesn't
  apply it, so the using module still sees the old state. It needs the merge
  setting above.

## The underlying rule

Mocks get you through `plan` and `validate`. The using module can't `apply`
successfully until the dependency's new output has been applied for real, so
apply the dependency first.
