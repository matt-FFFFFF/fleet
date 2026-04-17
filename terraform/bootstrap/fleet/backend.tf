# bootstrap/fleet intentionally uses LOCAL state — this stage creates the
# remote backend for every other stage. The lockfile (.terraform.lock.hcl)
# is committed; terraform.tfstate is gitignored at repo root.
#
# When re-running this stage on a non-fresh machine, run
# `terraform init -migrate-state` after `terraform state pull > backup.tfstate`.

terraform {
  # No `backend {}` block — defaults to `local`.
}
