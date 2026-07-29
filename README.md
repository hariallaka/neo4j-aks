# neo4j-aks

Terraform + Azure DevOps pipelines for a multi-tenant Neo4j Enterprise
deployment on Azure Kubernetes Service (AKS): one shared AKS cluster and one
shared Neo4j DBMS, onboarding each usecase/tenant as its own Neo4j database
with its own roles, and its own Entra ID (managed identity / service
principal) access via Neo4j's native OIDC/SSO support.

## Repository layout

```
terraform/            AKS cluster, node pools, Key Vault, Neo4j Helm release.
onboarding/            Cypher templates + shell runner to onboard/offboard a tenant or identity.
azure-pipelines/       Azure DevOps pipeline YAML that runs the onboarding scripts on demand.
```

## Architecture

### AKS cluster (`terraform/aks.tf`, `terraform/node_pools.tf`)

- A **system** node pool (`only_critical_addons_enabled = true`) runs only
  cluster-critical add-ons; all workloads, including Neo4j, are tainted off
  it.
- Two shared, size-tiered **user** node pools, `small` and `large`
  (`node_pools.tf`), each labeled/tainted (`workloadsize=small|large`).
  Tenants aren't isolated at the node level here — every tenant's Neo4j
  data lives in one shared Neo4j DBMS (see below) — these tiers just
  separate workload sizing from the system pool and from each other.
- Security baseline: Azure AD (Entra ID) RBAC for cluster access
  (`azure_active_directory_role_based_access_control`), Azure CNI with
  Azure's network policy engine (pod-to-pod `NetworkPolicy` enforcement),
  the Key Vault Secrets Provider CSI addon, Microsoft Defender for
  Containers, and an optional API server IP allowlist. See the comments in
  `aks.tf` for what's on by default vs. opt-in, and the trade-off around
  `local_account_disabled` (off by default — see below).

### Neo4j (`terraform/neo4j.tf`, `terraform/keyvault.tf`)

- One Neo4j **Enterprise** DBMS (`neo4j_edition = "enterprise"` by
  default), not a Helm release per tenant. Multi-tenancy is Neo4j's own
  multi-database feature: each onboarded usecase gets its own `CREATE
  DATABASE`, with roles/privileges scoped to that database.
- The generated admin password (`random_password.neo4j`) is stored in an
  Azure Key Vault (`azurerm_key_vault.this`) as `neo4j-admin-password`, in
  addition to being a Terraform output — treat your Terraform state as
  sensitive either way (encrypted remote backend, restricted access), since
  Terraform necessarily knows this value.
- OIDC/Entra ID auth config is added to `neo4j.conf` (via the chart's
  `config` map) only once `neo4j_oidc_client_id` is set — see **One-time
  Entra ID setup** below. Until then the stack applies fine with native
  auth only.

### Multi-tenant identity model

Rather than mapping Entra groups/app-roles directly to Neo4j roles, each
onboarded identity gets its own Neo4j user, linked to its Entra Object ID
via `CREATE USER ... SET AUTH 'oidc-azure' {SET ID '<object-id>'}`, then
granted a role natively (`GRANT ROLE ... TO ...`). Concretely, for tenant
`acmecorp`:

- Database: `acmecorp`
- Roles: `acmecorp_reader`, `acmecorp_writer`, `acmecorp_admin` — each
  scoped to the `acmecorp` database/graph only (see
  `onboarding/cypher/onboard-tenant.cypher.tpl`).
- Each managed identity/service principal onboarded to `acmecorp` gets its
  own Neo4j user granted exactly one of those three roles.

This means: (a) the Azure DevOps pipeline only ever needs to run Cypher
against Neo4j — no Microsoft Graph API calls to manage Entra app role
assignments — and (b) revoking one identity never affects another's access
to the same tenant.

`neo4j.conf` keeps `authentication_providers = "oidc-azure,native"` and
`authorization_providers = "native"` permanently (not switching to
OIDC-only): the onboarding pipeline itself authenticates as a native admin
account (password from Key Vault), which is the standard pattern for
automation — see the comments in `neo4j.tf`.

## One-time Entra ID setup

Before setting `neo4j_oidc_client_id`, register an app in Entra ID once
(Entra ID -> App registrations -> New registration — a name like `Neo4j
SSO` is fine). This is the same app registration used for both
interactive Neo4j Browser SSO and the machine-to-machine (managed
identity/service principal) access token validation described above; you
only need the M2M half if you don't plan to use Browser SSO.

Then set, in `terraform.tfvars`:

- `entra_tenant_id` — your Entra tenant (Directory) ID.
- `neo4j_oidc_client_id` — the app registration's Application (client) ID.

and re-apply. This wires up, in `neo4j.conf`:

```
dbms.security.authentication_providers=oidc-azure,native
dbms.security.authorization_providers=native
dbms.security.require_local_user=true
dbms.security.oidc.azure.audience=<client_id>
dbms.security.oidc.azure.issuer=https://login.microsoftonline.com/<tenant_id>/v2.0
dbms.security.oidc.azure.token_endpoint=https://login.microsoftonline.com/<tenant_id>/oauth2/v2.0/token
dbms.security.oidc.azure.well_known_discovery_uri=https://login.microsoftonline.com/<tenant_id>/v2.0/.well-known/openid-configuration
dbms.security.oidc.azure.claims.username=sub
```

**Before onboarding any identity**, confirm what claim your Entra-issued
access tokens actually populate for app-only (client credentials) tokens in
your tenant — Neo4j's own docs flag `sub` as the only claim guaranteed
stable/unique, but you should verify it's actually present and stable for
your managed identities/service principals (inspect a decoded token, e.g.
via [jwt.ms](https://jwt.ms)) before relying on it as the value passed to
`onboard-tenant.cypher.tpl`'s `ENTRA_OBJECT_ID` placeholder. If your tenant
doesn't populate `sub` for app-only tokens, switch
`dbms.security.oidc.azure.claims.username` to `oid` instead (and adjust
what value you onboard identities with to match).

## Onboarding a tenant / identity

See `onboarding/README.md` and `azure-pipelines/README.md` for full detail.
Short version: run the Azure DevOps pipeline in
`azure-pipelines/onboard-tenant-pipeline.yml` (or
`onboarding/scripts/render-and-run.sh` directly) with a tenant name, an
access level (`reader`/`writer`/`admin`), an identity name, and the
identity's Entra Object ID. It's idempotent — re-running it for an
already-onboarded tenant with a new identity just adds that identity,
without touching the existing database/roles/other identities.

## Prerequisites

- An Azure subscription, authenticated via `az login` or an
  `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID`
  service principal, with rights to create AKS, Key Vault, Log Analytics,
  and role assignments.
- A Neo4j Enterprise license agreement (or `neo4j_accept_license_agreement
  = "eval"` for evaluation use) — see
  [neo4j.com/licensing](https://neo4j.com/licensing/).
- An Azure DevOps project with a self-hosted agent pool that has network
  access to the Neo4j Bolt endpoint, if you'll use the pipelines
  (Microsoft-hosted agents can't reach a private AKS LoadBalancer/VNet).

## Usage

```bash
cd terraform
terraform init
cp terraform.tfvars.example terraform.tfvars   # then edit as needed
terraform apply -var-file="terraform.tfvars"
```

Get the generated Neo4j password and a usable kubeconfig afterwards:

```bash
terraform output -raw neo4j_initial_password   # also in Key Vault as neo4j-admin-password
terraform output -raw kube_config > kubeconfig
KUBECONFIG=./kubeconfig kubectl -n neo4j get svc   # find the LoadBalancer's external IP
```

Then see **Onboarding a tenant / identity** above.

## Testing

This was written and tested in a sandbox with no live Azure subscription
and whose network egress policy blocks `registry.terraform.io` (confirmed
via a 403 on `terraform init` — not something to route around per that
policy). Given that, what was actually done:

- `terraform fmt -check -diff -recursive` passes clean on every `.tf` file.
- The `helm_release` values (built as a Terraform `locals` map and passed
  via `yamlencode`) were rendered with real sample values through Python's
  `yaml` module to confirm the resulting structure matches the chart's own
  `values.yaml` shape (`neo4j.resources.*`, `volumes.data.dynamic.*`,
  `services.neo4j.spec.type`, `nodeSelector`, `podSpec.tolerations`,
  `config` as a flat dotted-key map).
- Every `azurerm_kubernetes_cluster`/`azurerm_kubernetes_cluster_node_pool`/
  `azurerm_key_vault` argument used here (`azure_active_directory_role_based_access_control`,
  `network_profile`, `key_vault_secrets_provider`, `microsoft_defender`,
  `api_server_access_profile`, `only_critical_addons_enabled`,
  `rbac_authorization_enabled`, etc.) was checked against the
  `hashicorp/azurerm` provider's own docs (fetched directly, not guessed)
  — see Sources.
- Every Cypher command in `onboarding/cypher/*.cypher.tpl` (`CREATE
  DATABASE ... IF NOT EXISTS`, `CREATE ROLE`, `GRANT ACCESS/MATCH/WRITE/
  START/STOP/INDEX MANAGEMENT/CONSTRAINT MANAGEMENT ON DATABASE|GRAPH`,
  `CREATE USER ... SET AUTH 'oidc-azure' {SET ID ...}`, `GRANT ROLE`,
  `DROP USER`) was checked against Neo4j's own Cypher/Operations Manual
  source (fetched directly from `neo4j/docs-operations` on GitHub) — see
  Sources.
- `onboarding/scripts/render-and-run.sh` was actually run end-to-end
  (`envsubst` installed locally) for both `onboard` and `offboard`, in
  `--dry-run` and against a stub `cypher-shell` that echoes its invocation,
  confirming: correct Cypher rendering, correct `cypher-shell` flags
  (`-a`/`-u`/`-p`/`--format`/`-f`), rejection of an injection attempt in the
  tenant name, rejection of an invalid access level, and a clear error
  (rather than a silent empty-string) when required env vars are unset.
  This caught and fixed one real bug (a duplicated `-a` flag).
- The Azure DevOps pipeline/template YAML files were parsed with Python's
  `yaml.safe_load` to confirm they're syntactically valid; the pipelines
  themselves haven't been run against a real Azure DevOps project or a
  real Neo4j instance.

Before relying on this in production: run `terraform init && terraform
validate` where `registry.terraform.io` is reachable, `terraform
plan`/`apply` against a real Azure subscription (ideally a disposable
resource group first), and run the onboarding pipeline in `--dry-run`
against a real Neo4j instance before turning dry-run off.

## Sources

- [neo4j/helm-charts values.yaml](https://github.com/neo4j/helm-charts/blob/dev/neo4j/values.yaml)
- [Neo4j Kubernetes deployment — Operations Manual](https://neo4j.com/docs/operations-manual/current/kubernetes/introduction/)
- [Configuring Neo4j Single Sign-On (SSO) — Operations Manual](https://github.com/neo4j/docs-operations/blob/main/modules/ROOT/pages/tutorial/tutorial-sso-configuration.adoc)
- [Manage users — Operations Manual](https://github.com/neo4j/docs-operations/blob/main/modules/ROOT/pages/authentication-authorization/manage-users.adoc)
- [Manage privileges — Operations Manual](https://github.com/neo4j/docs-operations/blob/main/modules/ROOT/pages/authentication-authorization/manage-privileges.adoc)
- [Database administration — Operations Manual](https://github.com/neo4j/docs-operations/blob/main/modules/ROOT/pages/authentication-authorization/database-administration.adoc)
- [Cypher Shell — Operations Manual](https://github.com/neo4j/docs-operations/blob/main/modules/ROOT/pages/cypher-shell.adoc)
- [azurerm_kubernetes_cluster (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster)
- [azurerm_kubernetes_cluster_node_pool (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool)
- [azurerm_key_vault (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault)
