# init/ — one-shot Terraform root module that renders adopter identity into
# the fleet repo. Invoked by ../init-fleet.sh after adopter values have been
# captured into inputs.auto.tfvars. After a successful apply, the wrapper
# shell script deletes this directory, the script itself, and the selftest
# workflow so the adopter repo ends up clean.
#
# Why Terraform? It's already a hard dependency for bootstrap, and it gives
# us typed inputs, per-field validation, and templatefile() — replacing a
# brittle sed pipeline over __UPPER_SNAKE__ tokens.
#
# This module has no providers beyond hashicorp/local: it renders files and
# produces no cloud-side state. It is safe to `terraform destroy` (which the
# wrapper does not do) but there is no reason to — the whole directory is
# removed post-apply.

terraform {
  required_version = "~> 1.9"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
