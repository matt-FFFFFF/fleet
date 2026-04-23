terraform {
  required_version = "~> 1.14"
  # No providers. This module is pure HCL: locals in, locals out.
  # Keeping the required_providers block absent (rather than an empty
  # map) means `terraform test` does not insist on mock_provider blocks
  # for non-existent providers.
}
