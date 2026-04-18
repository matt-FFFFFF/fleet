# -----------------------------------------------------------------------------
# Repository rulesets
# -----------------------------------------------------------------------------

module "ruleset" {
  source   = "./modules/ruleset"
  for_each = var.rulesets

  repository    = local.repository
  name          = each.value.name
  enforcement   = each.value.enforcement
  target        = each.value.target
  bypass_actors = each.value.bypass_actors
  conditions    = each.value.conditions
  rules         = each.value.rules
}
