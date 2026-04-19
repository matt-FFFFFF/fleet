<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.20 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | ~> 2.0 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.20 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_container_registry"></a> [container\_registry](#module\_container\_registry) | Azure/avm-res-containerregistry-registry/azurerm | 0.5.1 |

## Resources

| Name | Type |
|------|------|
| [azapi_update_resource.network_rule_bypass_allowed_for_tasks](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/update_resource) | resource |
| [azurerm_container_registry_task.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry_task) | resource |
| [azurerm_container_registry_task_schedule_run_now.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry_task_schedule_run_now) | resource |
| [azurerm_role_assignment.container_registry_pull_for_container_instance](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.container_registry_push_for_task](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_container_compute_identity_principal_id"></a> [container\_compute\_identity\_principal\_id](#input\_container\_compute\_identity\_principal\_id) | The principal id of the managed identity used by the container compute to pull images from the container registry | `string` | n/a | yes |
| <a name="input_images"></a> [images](#input\_images) | A map of objects that define the images to build in the container registry. The key of the map is the name of the image and the value is an object with the following attributes:<br/><br/>- `task_name` - The name of the task to create for building the image (e.g. `image-build-task`)<br/>- `dockerfile_path` - The path to the Dockerfile to use for building the image (e.g. `dockerfile`)<br/>- `context_path` - The path to the context of the Dockerfile in three sections `<repository-url>#<repository-commit>:<repository-folder-path>` (e.g. https://github.com/Azure/terraform-azurerm-avm-ptn-cicd-agents-and-runners#8ff4b85:container-images/azure-devops-agent)<br/>- `context_access_token` - The access token to use for accessing the context. Supply a PAT if targetting a private repository.<br/>- `image_names` - A list of the names of the images to build (e.g. `["image-name:tag"]`) | <pre>map(object({<br/>    task_name            = string<br/>    dockerfile_path      = string<br/>    context_path         = string<br/>    context_access_token = optional(string, "a") # This `a` is a dummy value because the context_access_token should not be required in the provider<br/>    image_names          = list(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region where the resource should be deployed. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | The name of the container registry | `string` | n/a | yes |
| <a name="input_private_dns_zone_id"></a> [private\_dns\_zone\_id](#input\_private\_dns\_zone\_id) | The id of the private DNS zone to create for the container registry. Only required if `container_registry_private_dns_zone_creation_enabled` is `false` and you are not using policy to update the DNS zone. | `string` | `null` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | The name of the resource group in which to create the container registry | `string` | n/a | yes |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | The id of the subnet to use for the private endpoint | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) Tags of the resource. | `map(string)` | `null` | no |
| <a name="input_use_private_networking"></a> [use\_private\_networking](#input\_use\_private\_networking) | Whether to use private networking for the container registry | `bool` | n/a | yes |
| <a name="input_use_zone_redundancy"></a> [use\_zone\_redundancy](#input\_use\_zone\_redundancy) | Enable zone redundancy for the deployment | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_login_server"></a> [login\_server](#output\_login\_server) | The login server of the container registry |
| <a name="output_name"></a> [name](#output\_name) | The name of the container registry |
| <a name="output_resource_id"></a> [resource\_id](#output\_resource\_id) | The ID of the container registry |
<!-- END_TF_DOCS -->