# Fixture for template-selftest.yaml. Overlaid onto init/inputs.auto.tfvars
# by init-fleet.sh --values-file so the repo can be validated end-to-end
# without prompts. Values are synthetic; real adopters use their own.

fleet_name         = "acme"
fleet_display_name = "Acme Platform"
tenant_id          = "11111111-1111-1111-1111-111111111111"
github_org         = "acme-co"
github_repo        = "platform-fleet"
team_template_repo = "team-repo-template"
primary_region     = "eastus"
sub_shared         = "22222222-2222-2222-2222-222222222222"
sub_mgmt           = "33333333-3333-3333-3333-333333333333"
sub_nonprod        = "44444444-4444-4444-4444-444444444444"
sub_prod           = "55555555-5555-5555-5555-555555555555"
dns_fleet_root     = "int.acme.example"
