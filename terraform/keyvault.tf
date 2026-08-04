resource "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
}

# Whoever/whatever runs `terraform apply` needs write access to create the
# secret below. Defaults to the caller's own object ID; override with a
# dedicated admin group/SP if that's not who should hold standing access.
resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = coalesce(var.key_vault_admin_object_id, data.azurerm_client_config.current.object_id)
}

# Lets AKS's Key Vault Secrets Provider (CSI driver) managed identity read
# secrets out of this vault, for pods that mount them via SecretProviderClass.
resource "azurerm_role_assignment" "kv_aks_csi" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
}

# System-of-record copy of the generated Neo4j admin password (see
# random_password.neo4j in neo4j.tf), so operators can retrieve it from Key
# Vault instead of `terraform output`.
resource "azurerm_key_vault_secret" "neo4j_admin_password" {
  name         = "neo4j-admin-password"
  value        = random_password.neo4j.result
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

# Only created when var.neo4j_pipeline_client_secret is actually supplied
# (that app registration/service principal is created manually in Entra,
# same one-time-setup pattern as neo4j_oidc_client_id -- see README). The
# Azure DevOps variable group that already links neo4j-admin-password
# (azure-pipelines/README.md) should link this one too, exposed as
# PIPELINE_CLIENT_SECRET, once NEO4J_AUTH_MODE=oidc is in use.
resource "azurerm_key_vault_secret" "neo4j_pipeline_client_secret" {
  count = var.neo4j_pipeline_client_secret != "" ? 1 : 0

  name         = "neo4j-pipeline-client-secret"
  value        = var.neo4j_pipeline_client_secret
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_admin]
}
