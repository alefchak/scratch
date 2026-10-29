# Using module: reads an output the dependency doesn't have in state yet.

dependency "foo" {
  config_path = "../foo"

  # Placeholder for the new, not-yet-applied output.
  mock_outputs = {
    new_output = "mock-value"
  }

  # Mocks are only used for these commands. Leave apply out so a real apply
  # fails loudly instead of using a fake value.
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]

  # Real outputs from state win; keys missing from state come from the mocks.
  # Without this (default "no_merge"), mocks are ignored as soon as the
  # dependency has any outputs in state.
  # Older Terragrunt: mock_outputs_merge_with_state = true
  mock_outputs_merge_strategy_with_state = "shallow"
}

inputs = {
  new_output = dependency.foo.outputs.new_output
}
