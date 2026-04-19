<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.20 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.20 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_container_group.alz](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_group) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_availability_zones"></a> [availability\_zones](#input\_availability\_zones) | List of availability zones | `list(string)` | `null` | no |
| <a name="input_container_cpu"></a> [container\_cpu](#input\_container\_cpu) | CPU value for the container | `number` | `2` | no |
| <a name="input_container_cpu_limit"></a> [container\_cpu\_limit](#input\_container\_cpu\_limit) | CPU limit for the container | `number` | `2` | no |
| <a name="input_container_image"></a> [container\_image](#input\_container\_image) | Image of the container | `string` | n/a | yes |
| <a name="input_container_instance_name"></a> [container\_instance\_name](#input\_container\_instance\_name) | Name of the container instance | `string` | n/a | yes |
| <a name="input_container_memory"></a> [container\_memory](#input\_container\_memory) | Memory value for the container | `number` | `4` | no |
| <a name="input_container_memory_limit"></a> [container\_memory\_limit](#input\_container\_memory\_limit) | Memory limit for the container | `number` | `4` | no |
| <a name="input_container_name"></a> [container\_name](#input\_container\_name) | Name of the container | `string` | n/a | yes |
| <a name="input_container_registry_login_server"></a> [container\_registry\_login\_server](#input\_container\_registry\_login\_server) | Login server of the container registry | `string` | n/a | yes |
| <a name="input_container_registry_password"></a> [container\_registry\_password](#input\_container\_registry\_password) | Password of the container registry | `string` | `null` | no |
| <a name="input_container_registry_username"></a> [container\_registry\_username](#input\_container\_registry\_username) | Username of the container registry | `string` | `null` | no |
| <a name="input_environment_variables"></a> [environment\_variables](#input\_environment\_variables) | Environment variables for the container | `map(string)` | `{}` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region where the resource should be deployed. | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_sensitive_environment_variables"></a> [sensitive\_environment\_variables](#input\_sensitive\_environment\_variables) | Secure environment variables for the container | `map(string)` | `{}` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | ID of the subnet | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) Tags of the resource. | `map(string)` | `null` | no |
| <a name="input_use_private_networking"></a> [use\_private\_networking](#input\_use\_private\_networking) | Flag to indicate whether to use private networking | `bool` | `true` | no |
| <a name="input_user_assigned_managed_identity_id"></a> [user\_assigned\_managed\_identity\_id](#input\_user\_assigned\_managed\_identity\_id) | ID of the user-assigned managed identity | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_name"></a> [name](#output\_name) | The name of the container instance |
| <a name="output_resource"></a> [resource](#output\_resource) | The container instance resource |
| <a name="output_resource_id"></a> [resource\_id](#output\_resource\_id) | The ID of the container instance |
<!-- END_TF_DOCS -->