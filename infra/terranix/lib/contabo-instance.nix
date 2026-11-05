# A Contabo VPS that was bought in the Contabo panel and imported with
# `nix run .#adopt -- <host> <instance-id>`. Terraform tracks it (state in R2,
# outputs, display name) but is never allowed to create, reinstall or cancel it.
#
# Why the lifecycle block matters (contabo/contabo 0.1.44 source):
# - No attribute is ForceNew. Changing image_id, ssh_keys, user_data,
#   root_password or default_user shows as "~ update in-place" but calls
#   Contabo's reinstall API, which wipes the disk. prevent_destroy does not
#   catch that, so those attributes are ignored.
# - region, period, default_user and user_data are never read back from the
#   API, so after an import they would always look changed. Ignored too.
# - Destroy calls the cancel-contract API. prevent_destroy blocks it.
# scripts/provisioning/plan-guard.jq re-checks all of this on every plan.
{ lib }:
{
  name,
  displayName ? name,
  productId,
  region ? "EU",
  period ? 1,
}:
let
  instance = "contabo_instance.${name}";
in
{
  terraform.required_version = ">= 1.6.0";

  terraform.backend.s3 = { };

  terraform.required_providers.contabo = {
    source = "contabo/contabo";
    version = "= 0.1.44";
  };

  # Credentials come from CNTB_OAUTH2_CLIENT_ID, CNTB_OAUTH2_CLIENT_SECRET,
  # CNTB_OAUTH2_USER and CNTB_OAUTH2_PASS.
  provider.contabo = { };

  resource.contabo_instance.${name} = {
    display_name = displayName;
    # Read back by the provider: a mismatch shows up in plan and the guard refuses it.
    product_id = productId;
    region = region;
    period = period;

    lifecycle = {
      prevent_destroy = true;
      ignore_changes = [
        # reinstall triggers
        "image_id"
        "ssh_keys"
        "user_data"
        "root_password"
        "default_user"
        # not read back after import / create-time only
        "region"
        "period"
        "license"
        "add_ons"
        "existing_instance_id"
      ];
    };
  };

  output.instance_id.value = "\${${instance}.id}";
  output.product_id.value = "\${${instance}.product_id}";
  output.status.value = "\${${instance}.status}";
  output.cancel_date.value = "\${${instance}.cancel_date}";
  output.mac_address.value = "\${${instance}.mac_address}";
  output.ipv4.value = "\${${instance}.ip_config[0].v4[0].ip}";
  output.ipv4_prefix_length.value = "\${${instance}.ip_config[0].v4[0].netmask_cidr}";
  output.ipv4_gateway.value = "\${${instance}.ip_config[0].v4[0].gateway}";
  output.ipv6.value = "\${try(${instance}.ip_config[0].v6[0].ip, null)}";
  output.ipv6_prefix_length.value = "\${try(${instance}.ip_config[0].v6[0].netmask_cidr, null)}";
  output.ipv6_gateway.value = "\${try(${instance}.ip_config[0].v6[0].gateway, null)}";
}
