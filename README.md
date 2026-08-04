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
- Deployed as `var.neo4j_cluster_size` cluster members (default `3`), each
  its own Helm release/pod/PVC — see **High availability (clustering)**
  below for how that works and what it requires.
- The generated admin password (`random_password.neo4j`) is stored in an
  Azure Key Vault (`azurerm_key_vault.this`) as `neo4j-admin-password`, in
  addition to being a Terraform output — treat your Terraform state as
  sensitive either way (encrypted remote backend, restricted access), since
  Terraform necessarily knows this value.
- OIDC/Entra ID auth config is added to `neo4j.conf` (via the chart's
  `config` map) only once `neo4j_oidc_client_id` is set — see **One-time
  Entra ID setup** below. Until then the stack applies fine with native
  auth only.

## High availability (clustering)

`var.neo4j_cluster_size` (default `3`) controls how many Neo4j cluster
members get deployed. Neo4j HA isn't a replica count on one Deployment —
each member is its own Helm release, tied to the others by a shared
`neo4j.name` (`var.neo4j_release_name`), same admin password, and the same
`minimumClusterSize`. `neo4j.tf` loops `helm_release.neo4j` over
`local.neo4j_release_names` to install one release per member
(`<neo4j_release_name>-0`, `-1`, `-2`, ...; `neo4j_cluster_size = 1` keeps
the original single, unsuffixed release name).

- **Set `neo4j_cluster_size = 1`** for a standalone instance (no
  clustering, the behavior before HA support existed).
- **Set it to `3` (default) or `5`** for clustering. Neo4j's fault
  tolerance follows `M = 2F+1`: 3 members tolerate 1 failure and keep
  write availability, 5 tolerate 2. It must be **odd** — Raft consensus
  needs a majority, and an even member count adds a node without adding
  fault tolerance (enforced by a `validation` block on the variable).
- Pod anti-affinity (keeping members off the same AKS node) is the chart's
  own default (`podSpec.podAntiAffinity: true`) — nothing extra to
  configure — but the target node pool (`neo4j_node_pool_tier`) needs at
  least `neo4j_cluster_size` schedulable nodes, or member pods beyond the
  pool's node count will stay `Pending`. A `check` block in `neo4j.tf`
  warns (non-fatally, at `plan`/`apply`) if `small_pool_node_count` /
  `large_pool_node_count` is too low for the tier you picked.
- A cluster-wide `kubernetes_pod_disruption_budget_v1`
  (`neo4j_cluster` in `neo4j.tf`, only created when `neo4j_cluster_size >=
  3`) caps voluntary disruptions (e.g. AKS node drains during upgrades) at
  the same `F` from the fault-tolerance formula, so routine cluster
  maintenance can't accidentally take the DBMS below quorum.
- The external `services.neo4j` LoadBalancer is a single Service shared
  across all members (keyed by `neo4j.name`, not release name, and kept
  alive across releases via the chart's own `helm.sh/resource-policy:
  keep` annotation) — you still get one public IP for the whole cluster,
  not one per pod. Neo4j client drivers using the `neo4j://` routing
  scheme handle discovering and routing to the current writer themselves.
- To see all members together: `kubectl -n neo4j get pods -l
  helm.neo4j.com/neo4j.name=<neo4j_release_name>` (defaults to
  `neo4j-aks`).

### Licensing caveat — read this before setting `neo4j_cluster_size` above 1

`neo4j_accept_license_agreement` only toggles a chart flag
(`"yes"`/`"eval"`) — Terraform and the Helm chart have no way to check
what your actual Neo4j license agreement entitles you to run, and the
chart applies the same flag identically to every cluster member regardless
of member count. **A single-server-instance license (e.g. the kind also
usable in Neo4j Desktop) is very likely scoped to one non-clustered
instance and does not itself authorize deploying a multi-member Enterprise
cluster** — clustering entitlement is typically a separate/higher tier in
Neo4j's commercial terms. Confirm with your Neo4j agreement or account
rep before running this with `neo4j_cluster_size > 1` against anything
that isn't purely a technical trial; the `check` blocks in `neo4j.tf`
only validate the *edition*/*license-flag* combination is internally
consistent, not that your specific license covers clustering.

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
KUBECONFIG=./kubeconfig kubectl -n neo4j get pods -l helm.neo4j.com/neo4j.name=neo4j-aks   # all cluster members
```

Then see **Onboarding a tenant / identity** above.

## Testing

This was written and tested in a sandbox with no live Azure subscription
and whose network egress policy blocks `registry.terraform.io` (confirmed
via a 403 on `terraform init` — not something to route around per that
policy). Given that, what was actually done:

- `terraform fmt -check -diff -recursive` passes clean on every `.tf` file
  (the `neo4j_cluster_size`/multi-release changes were hand-aligned to
  match, since this sandbox has no `terraform` binary to run `fmt` with —
  re-run it for real before applying).
- The `helm_release` values (built as a Terraform `locals` map and passed
  via `yamlencode`) were rendered with real sample values through Python's
  `yaml` module to confirm the resulting structure matches the chart's own
  `values.yaml` shape (`neo4j.resources.*`, `neo4j.minimumClusterSize`,
  `volumes.data.dynamic.*`, `services.neo4j.spec.type`, `nodeSelector`,
  `podSpec.tolerations`, `config` as a flat dotted-key map), and the
  `for_each` release-name map (`local.neo4j_release_names`) was rendered
  the same way to confirm it produces `<name>-0`/`-1`/`-2` for
  `neo4j_cluster_size = 3` and the original unsuffixed name for `= 1`.
- The Neo4j Helm chart's own `values.yaml`/templates (fetched directly from
  `neo4j/helm-charts` on GitHub, not guessed) were checked to confirm:
  clustering ties members together via `neo4j.name` rather than Helm
  release name; `podSpec.podAntiAffinity` defaults to `true`; the
  `services.neo4j` LoadBalancer is one Service shared across a cluster's
  releases (`helm.sh/resource-policy: keep`); and cluster pods carry the
  label `helm.neo4j.com/neo4j.name` used here for the `kubectl` selector
  and the `kubernetes_pod_disruption_budget_v1` selector.
- `kubernetes_pod_disruption_budget_v1`'s `max_unavailable`/`min_available`
  are strings in the `hashicorp/kubernetes` provider (checked against the
  provider docs) — `neo4j.tf` wraps the computed value in `tostring()`
  accordingly.
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
