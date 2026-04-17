# TFLint configuration shared across every Terraform root/module in
# the repo. Run with `tflint --recursive` from the repo root; CI runs
# this via .github/workflows/tflint.yaml.
#
# The bundled `terraform` ruleset catches unused declarations, naming
# drift, missing module pins, and deprecated syntax — the cheapest way
# to keep bootstrap/stage HCL honest without running a plan.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Unused-declaration enforcement is the main motivation for this
# config. Part of `recommended` above; called out explicitly so it
# can't be accidentally downgraded.
rule "terraform_unused_declarations" {
  enabled = true
}

# Snake-case names for locals/variables/resources.
rule "terraform_naming_convention" {
  enabled = true
}

# Standard main.tf / variables.tf / outputs.tf layout is a Phase-7
# hardening target (see PLAN §13 Phase 7). Many Phase-1 stubs
# (bootstrap/team, stages/0-fleet providers-only scaffold) intentionally
# don't conform yet. Re-enable when those fill in.
rule "terraform_standard_module_structure" {
  enabled = false
}
