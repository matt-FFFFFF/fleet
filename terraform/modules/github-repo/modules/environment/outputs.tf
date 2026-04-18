output "environment" {
  description = "The environment resource."
  value = {
    id          = github_repository_environment.this.id
    environment = github_repository_environment.this.environment
  }
}

output "variables" {
  description = "Map of environment variable names to their values."
  value = {
    for k, v in github_actions_environment_variable.this : k => {
      name  = v.variable_name
      value = v.value
    }
  }
}

output "secrets" {
  description = "Map of environment secret names (values are not exposed)."
  value = {
    for k, v in github_actions_environment_secret.this : k => {
      secret_name = v.secret_name
    }
  }
}

output "deployment_policies" {
  description = "Map of deployment policy keys to their patterns."
  value = {
    for k, v in github_repository_environment_deployment_policy.this : k => {
      id             = v.id
      branch_pattern = v.branch_pattern
      tag_pattern    = v.tag_pattern
    }
  }
}

output "identity" {
  description = "The managed identity and federated credential for the environment (null when identity is not configured)."
  value = var.identity != null ? {
    id           = azapi_resource.identity[0].id
    name         = azapi_resource.identity[0].name
    principal_id = azapi_resource.identity[0].output.properties.principalId
    client_id    = azapi_resource.identity[0].output.properties.clientId
    tenant_id    = azapi_resource.identity[0].output.properties.tenantId
    federated_credential = {
      id      = azapi_resource.federated_identity_credential[0].id
      subject = local.federated_subject
    }
  } : null
}

output "role_assignments" {
  description = "Map of role assignment keys to their resource details."
  value = {
    for k, v in azapi_resource.role_assignment : k => {
      id                 = v.id
      name               = v.name
      scope              = var.role_assignments[k].scope
      role_definition_id = var.role_assignments[k].role_definition_id
    }
  }
}
