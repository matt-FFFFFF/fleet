<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | 2.9.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azapi_resource.job](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.placeholder](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource_action.placeholder_trigger](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource_action) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_container_app_environment_id"></a> [container\_app\_environment\_id](#input\_container\_app\_environment\_id) | The resource id of the Container App Environment. | `string` | n/a | yes |
| <a name="input_container_cpu"></a> [container\_cpu](#input\_container\_cpu) | Required CPU in cores, e.g. 0.5 | `number` | n/a | yes |
| <a name="input_container_image_name"></a> [container\_image\_name](#input\_container\_image\_name) | Fully qualified name of the Docker image the agents should run. | `string` | n/a | yes |
| <a name="input_container_memory"></a> [container\_memory](#input\_container\_memory) | Required memory, e.g. '250Mb' | `string` | n/a | yes |
| <a name="input_environment_variables"></a> [environment\_variables](#input\_environment\_variables) | List of environment variables to pass to the container. | <pre>set(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | n/a | yes |
| <a name="input_environment_variables_placeholder"></a> [environment\_variables\_placeholder](#input\_environment\_variables\_placeholder) | List of environment variables to pass only to the placeholder container. | <pre>set(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_github_app_key_identity_id"></a> [github\_app\_key\_identity\_id](#input\_github\_app\_key\_identity\_id) | (Optional.) UAMI resource id used by the Container App to read `github_app_key_kv_secret_id`. | `string` | `null` | no |
| <a name="input_github_app_key_kv_secret_id"></a> [github\_app\_key\_kv\_secret\_id](#input\_github\_app\_key\_kv\_secret\_id) | (Optional.) Versionless Key Vault secret URI for the GitHub App PEM. When set, the `application-key` secret is emitted as a KV reference. | `string` | `null` | no |
| <a name="input_job_container_name"></a> [job\_container\_name](#input\_job\_container\_name) | The name of the container for the runner Container Apps job. | `string` | n/a | yes |
| <a name="input_job_name"></a> [job\_name](#input\_job\_name) | The name of the Container App job. | `string` | n/a | yes |
| <a name="input_keda_meta_data"></a> [keda\_meta\_data](#input\_keda\_meta\_data) | The metadata for the KEDA scaler. | `map(string)` | n/a | yes |
| <a name="input_keda_rule_type"></a> [keda\_rule\_type](#input\_keda\_rule\_type) | The type of the KEDA rule. | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region where the resource should be deployed. | `string` | n/a | yes |
| <a name="input_managed_identity_auth_enabled"></a> [managed\_identity\_auth\_enabled](#input\_managed\_identity\_auth\_enabled) | Whether to use managed identity for KEDA authentication instead of PAT. | `bool` | `false` | no |
| <a name="input_max_execution_count"></a> [max\_execution\_count](#input\_max\_execution\_count) | The maximum number of executions to spawn per polling interval. | `number` | n/a | yes |
| <a name="input_min_execution_count"></a> [min\_execution\_count](#input\_min\_execution\_count) | The minimum number of executions to spawn per polling interval. | `number` | n/a | yes |
| <a name="input_placeholder_container_name"></a> [placeholder\_container\_name](#input\_placeholder\_container\_name) | The name of the container for the placeholder Container Apps job. | `string` | `null` | no |
| <a name="input_placeholder_job_creation_enabled"></a> [placeholder\_job\_creation\_enabled](#input\_placeholder\_job\_creation\_enabled) | Whether or not to create a placeholder job. | `bool` | `false` | no |
| <a name="input_placeholder_job_name"></a> [placeholder\_job\_name](#input\_placeholder\_job\_name) | The name of the Container App placeholder job. | `string` | `null` | no |
| <a name="input_placeholder_replica_retry_limit"></a> [placeholder\_replica\_retry\_limit](#input\_placeholder\_replica\_retry\_limit) | The number of times to retry the placeholder Container Apps job. | `number` | `3` | no |
| <a name="input_placeholder_replica_timeout"></a> [placeholder\_replica\_timeout](#input\_placeholder\_replica\_timeout) | The timeout in seconds for the placeholder Container Apps job. | `number` | `300` | no |
| <a name="input_polling_interval_seconds"></a> [polling\_interval\_seconds](#input\_polling\_interval\_seconds) | How often should the pipeline queue be checked for new events, in seconds. | `number` | n/a | yes |
| <a name="input_postfix"></a> [postfix](#input\_postfix) | Postfix used for naming the resources where the name isn't supplied. | `string` | n/a | yes |
| <a name="input_registry_login_server"></a> [registry\_login\_server](#input\_registry\_login\_server) | The login server of the container registry. | `string` | n/a | yes |
| <a name="input_registry_password"></a> [registry\_password](#input\_registry\_password) | Password of the container registry. | `string` | `null` | no |
| <a name="input_registry_username"></a> [registry\_username](#input\_registry\_username) | Name of the container registry. | `string` | `null` | no |
| <a name="input_replica_retry_limit"></a> [replica\_retry\_limit](#input\_replica\_retry\_limit) | The number of times to retry the runner Container Apps job. | `number` | n/a | yes |
| <a name="input_replica_timeout"></a> [replica\_timeout](#input\_replica\_timeout) | The timeout in seconds for the runner Container Apps job. | `number` | n/a | yes |
| <a name="input_resource_group_id"></a> [resource\_group\_id](#input\_resource\_group\_id) | The id of the resource group where the resources will be deployed. | `string` | n/a | yes |
| <a name="input_retry"></a> [retry](#input\_retry) | Retry configuration for the resource operations | <pre>object({<br/>    error_message_regex  = optional(list(string), ["ReferencedResourceNotProvisioned"])<br/>    interval_seconds     = optional(number, 10)<br/>    max_interval_seconds = optional(number, 180)<br/>  })</pre> | `{}` | no |
| <a name="input_sensitive_environment_variables"></a> [sensitive\_environment\_variables](#input\_sensitive\_environment\_variables) | List of sensitive environment variables to pass to the container. | <pre>set(object({<br/>    name                      = string<br/>    value                     = string<br/>    container_app_secret_name = string<br/>    keda_auth_name            = optional(string)<br/>  }))</pre> | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) Tags of the resource. | `map(string)` | `null` | no |
| <a name="input_user_assigned_managed_identity_id"></a> [user\_assigned\_managed\_identity\_id](#input\_user\_assigned\_managed\_identity\_id) | The resource Id of the user assigned managed identity. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_name"></a> [name](#output\_name) | The name of the container app job. |
| <a name="output_placeholder_job_name"></a> [placeholder\_job\_name](#output\_placeholder\_job\_name) | The name of the placeholder job. |
| <a name="output_placeholder_job_resource"></a> [placeholder\_job\_resource](#output\_placeholder\_job\_resource) | The placeholder job resource. |
| <a name="output_placeholder_job_resource_id"></a> [placeholder\_job\_resource\_id](#output\_placeholder\_job\_resource\_id) | The resource id of the placeholder job. |
| <a name="output_resource_id"></a> [resource\_id](#output\_resource\_id) | The resource id of the container app job. |
| <a name="output_runner_job_resource"></a> [runner\_job\_resource](#output\_runner\_job\_resource) | The job resource. |
<!-- END_TF_DOCS -->