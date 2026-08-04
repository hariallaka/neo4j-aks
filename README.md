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
local-dev/             kind-based local harness for validating the Kubernetes/Helm/Istio layer without a real AKS cluster.
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
- Deployed as `var.neo4j_cluster_size` cluster members (default `1`,
  standalone), each its own Helm release/pod/PVC — see **High availability
  (clustering)** below for how that works and what it requires.
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

`var.neo4j_cluster_size` (default `1`, standalone) controls how many Neo4j cluster
members get deployed. Neo4j HA isn't a replica count on one Deployment —
each member is its own Helm release, tied to the others by a shared
`neo4j.name` (`var.neo4j_release_name`), same admin password, and the same
`minimumClusterSize`. `neo4j.tf` loops `helm_release.neo4j` over
`local.neo4j_release_names` to install one release per member
(`<neo4j_release_name>-0`, `-1`, `-2`, ...; `neo4j_cluster_size = 1` keeps
the original single, unsuffixed release name).

- **`neo4j_cluster_size = 1`** (default) is a standalone instance — no
  clustering, matching a single-instance license and the behavior before
  HA support existed.
- **Set it to `3` or `5`** for clustering. Neo4j's fault
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

### Deployment method: `helm_release` vs `helm_cli`

`var.neo4j_deployment_method` picks how the chart actually gets installed:

- **`"helm_release"`** (default) — Terraform's native `helm_release`
  resource (`helm_release.neo4j` in `neo4j.tf`), talking to the chart repo
  via the Terraform helm provider's own Go SDK.
- **`"helm_cli"`** — `neo4j-helm-cli.tf` instead renders the same values to
  a local file per member (`local_file.neo4j_values`) and shells out to
  whatever `helm` binary is on the machine running `terraform apply`
  (`null_resource.neo4j_helm_cli`, via a `local-exec` provisioner running
  `helm upgrade --install`). Use this if that machine's `helm` is already
  set up to reach the chart repo (proxy env vars, an internal mirror
  trusted by its CA bundle, etc.) in a way the Terraform helm provider
  can't easily be pointed at the same way. Requires `helm` and a working
  `kubectl`/kubeconfig context on that machine; `terraform plan` can't show
  chart-internal diffs for this path the way it can for `helm_release` —
  Terraform only sees an opaque `null_resource` that re-runs whenever the
  rendered values' hash (`values_sha256` trigger) changes.
- Only one method's resources exist per apply (the other's `for_each` is
  empty). **Switching methods on an already-deployed cluster doesn't
  migrate anything** — the newly-inactive method's resources drop out of
  Terraform's state, but the underlying Helm release stays installed in
  Kubernetes until you `helm uninstall` it by hand (or `terraform destroy`
  before switching).

### Chart repository access behind a proxy (exact URLs)

`var.neo4j_helm_repo_url` (default `https://helm.neo4j.com/neo4j`) is what
`helm repo add`/the Terraform helm provider's `repository` argument
resolves against — point it at an internal proxy/mirror if
`helm.neo4j.com` itself isn't reachable from your network. What that URL
actually needs to serve, concretely:

- **`<repo_url>/index.yaml`** — the chart repo index. For `neo4j`, this is
  a standard Helm `apiVersion: v1` index; the current entries' `urls:`
  fields point to `.tgz` chart packages.
- **The chart packages themselves are *not* hosted under `helm.neo4j.com`**
  — the index's `urls:` entries point straight at GitHub Releases, e.g.
  `https://github.com/neo4j/helm-charts/releases/download/2026.6.0/neo4j-2026.6.0.tgz`.
  So `helm.neo4j.com` is effectively just the index; the actual `.tgz`
  download always goes to `github.com`/`objects.githubusercontent.com`
  regardless of what `neo4j_helm_repo_url` points at, unless your mirror
  also rewrites those `urls:` entries to itself (which is exactly what an
  Artifactory/Nexus/Harbor "generic remote" Helm repo type does — it
  proxies the index *and* re-writes/caches the package URLs so clients
  never touch `github.com` directly).
- The same `index.yaml` content is also mirrored as a plain file in the
  `neo4j/helm-charts` GitHub repo itself, on its **`master`** branch (not
  `dev`, and there's no `gh-pages` branch): fetchable at
  `https://raw.githubusercontent.com/neo4j/helm-charts/master/index.yaml`.
  If your network already allows `raw.githubusercontent.com` but not
  `helm.neo4j.com`, this is a way to inspect available chart
  versions/URLs without needing `helm.neo4j.com` at all — but it doesn't
  by itself solve chart *downloads*, since the `urls:` inside it still
  point at `github.com/neo4j/helm-charts/releases/download/...`.
- Practical options for a proxy cache, in order of how much they insulate
  you from `helm.neo4j.com`/`github.com` outages or access issues:
  1. An internal Helm "generic remote" repo (Artifactory/Nexus/Harbor)
     configured to proxy `https://helm.neo4j.com/neo4j` — handles both the
     index and the package rewrite/caching automatically; point
     `neo4j_helm_repo_url` at your internal repo's URL.
  2. If only `github.com`/`raw.githubusercontent.com` are reachable (not
     `helm.neo4j.com`), download the specific chart `.tgz` you need
     directly from `github.com/neo4j/helm-charts/releases`, push it into
     an internal generic/OCI registry yourselves, and point
     `neo4j_helm_repo_url`/the chart source at that instead.
  3. `helm pull` the `.tgz` once (from wherever it *is* reachable) and use
     a local chart path — the Terraform helm provider's `chart` argument
     also accepts a filesystem path, not just a repo+chart name, if you'd
     rather vendor the chart into this repo than depend on any remote repo
     at apply time.

### Other Neo4j Helm charts in this monorepo

`neo4j/helm-charts` (same repo the `neo4j` chart comes from) ships several
other charts alongside it, all versioned/released together. None of these
are wired into this Terraform stack today — this is what they're for, if
you want to add them:

| Chart | What it does | Relevant here? |
|---|---|---|
| `neo4j` | The DBMS itself — what `neo4j.tf` deploys. | Already used. |
| `neo4j-admin` | A scheduled backup `CronJob` (despite the name, it's backups, not a general admin console) — runs `neo4j-admin database backup` against a running instance/cluster on a cron schedule, to cloud storage or a PVC. | Worth adding if you need automated backups; not currently in this stack. |
| `neo4j-headless-service` | An additional headless (`clusterIP: None`) Service selecting all members sharing a `neo4j.name`, for stable per-pod internal DNS names instead of (or alongside) the chart's own default/LoadBalancer Services. | Optional; `neo4j.tf`'s per-member Services already provide internal addressing. Its own docs note it's a valid backend target for `neo4j-reverse-proxy` below. |
| `neo4j-persistent-volume` / `neo4j-docker-desktop-pv` | Pre-provision disks/PVs for the `neo4j` chart to bind to, for storage setups where dynamic provisioning (what `neo4j.tf` uses via `managed-csi`) isn't the right fit, or for local Docker Desktop Kubernetes. | Not needed here — AKS's `managed-csi` dynamic provisioning already covers this. |
| `neo4j-reverse-proxy` | Deploys a small reverse-proxy pod that fronts both HTTP (Browser) and Bolt traffic behind a single port via WebSocket tunneling, wired through an `ingress-nginx` or `haproxy-ingress` Kubernetes Ingress. Built for networks where only 80/443 egress is allowed. | **Wired in** — see the next section (`terraform/ingress.tf`, `var.neo4j_reverse_proxy_enabled`). |

### Fronting Neo4j through Istio (`terraform/ingress.tf`)

`var.neo4j_reverse_proxy_enabled` (default `false`) deploys **Neo4j's own
`neo4j-reverse-proxy` chart plus an Istio `Gateway`/`VirtualService`**, for
end users who can only reach a raw HTTP(S) port (443) — not Bolt's 7687
directly. **This assumes Istio (istiod + an ingress gateway) is already
installed and managed in this AKS cluster outside this stack** — `ingress.tf`
doesn't install Istio itself, only the routing objects and the
`neo4j-reverse-proxy` backend they point at. A Kubernetes `Ingress`/Istio
`VirtualService` is HTTP(S)-only by design, so plain TCP can't go through
it — `neo4j-reverse-proxy` is what actually tunnels Bolt over WebSocket;
Istio just routes normal HTTP(S) traffic to that pod like any other
backend. Istio/Envoy handles the WebSocket upgrade automatically for HTTP
routes — no special `VirtualService` config needed for that part.

- **`helm_release.neo4j_reverse_proxy`** installs Neo4j's chart (same
  repo/version line as `neo4j` itself, so it also honors
  `neo4j_helm_repo_url`/`neo4j_helm_chart_version`), pointed at
  `<neo4j_release_name>-lb-neo4j` — the neo4j chart's own shared external
  Service (confirmed against Neo4j's "Access the Neo4j cluster from
  outside Kubernetes" doc). The chart's **own** `reverseProxy.ingress` is
  left `enabled: false` — Istio does the routing, not a chart-managed
  `Ingress` object — but its Service (`<release>-reverseproxy-service`)
  is still created and is what the `VirtualService` targets.
- **`kubectl_manifest.neo4j_reverse_proxy_gateway`** — an Istio `Gateway`
  binding to your **existing** ingress gateway workload via
  `var.istio_ingress_gateway_selector` (default `{istio:
  ingressgateway}`, Istio's own default label — override if yours differs)
  rather than provisioning a new gateway. Listens on 443/HTTPS with
  `tls.credentialName = neo4j_reverse_proxy_tls_secret_name` if set, else
  plain 80/HTTP.
- **`kubectl_manifest.neo4j_reverse_proxy_virtualservice`** — routes
  `neo4j_reverse_proxy_host` through that Gateway to the reverse-proxy
  Service. Both CRD resources go through the `gavinbunney/kubectl`
  provider's `kubectl_manifest` (added in `versions.tf`/`providers.tf`) —
  the mainline `hashicorp/kubernetes` provider has no generic resource for
  arbitrary CRDs, and Istio's own CRDs obviously aren't installed by this
  stack for a typed provider to target. **Required:**
  `neo4j_reverse_proxy_host` whenever this is enabled — enforced by a
  `check` block (depends on another variable, so it can't be a plain
  variable `validation`).
- **TLS secret location — an Istio-specific gotcha.** Istio's ingress
  gateway typically needs `tls.credentialName`'s Secret to live in **its
  own** namespace (commonly `istio-system`), not the Neo4j namespace,
  for its SDS credential access to see it — confirm this against however
  your specific Istio install is configured (cross-namespace secret
  discovery is possible but not default). Provisioning the certificate
  itself (cert-manager, Key Vault, a manually created Secret) is outside
  this stack either way.
- **Node placement.** Both the `neo4j-reverse-proxy` pod and (once
  someone points the existing gateway install at it — see next) the Istio
  ingress gateway itself run on a **dedicated `ingress` node pool**
  (`azurerm_kubernetes_cluster_node_pool.ingress` in `node_pools.tf`, only
  created when `neo4j_reverse_proxy_enabled = true`) — not the tenant
  `small`/`large` pools Neo4j uses, and not the AKS system pool. Sized via
  `ingress_pool_vm_size`/`ingress_pool_node_count`.
- **This repo creating the `ingress` pool does not, by itself, move the
  already-installed Istio ingress gateway onto it** — that gateway's
  Deployment is managed outside this repo, so someone needs to add a
  matching `nodeSelector`/`toleration` on that side:
  ```yaml
  nodeSelector:
    workload: ingress
  tolerations:
    - key: workload
      operator: Equal
      value: ingress
      effect: NoSchedule
  ```
  (`terraform output ingress_node_pool_name` confirms the pool exists once
  applied.) Until that's done, the gateway keeps running wherever it runs
  today — routing still works either way, since Istio's Gateway/
  VirtualService bind by pod label, not by node pool.
- **After `apply`:** find your Istio ingress gateway's external IP (however
  you normally do — e.g. `kubectl -n istio-system get svc`) and point
  `neo4j_reverse_proxy_host`'s DNS record at it. End users then connect the
  same way they always would — `neo4j://<reverse_proxy_host>` (or
  `neo4j+s://` once TLS is wired up) — nothing Bolt-driver-specific to
  configure on their end; the WebSocket tunneling is invisible to the
  driver.

**If your actual goal is just "one shared front door" rather than
"80/443-only egress,"** this specific setup is more than you need: a plain
Istio `Gateway` with `protocol: TCP` (or `TLS` for passthrough), routing
straight to `services.neo4j` (Neo4j's own LoadBalancer Service, `neo4j.tf`)
via a `TCPRoute`-style `VirtualService`, is simpler and works the same way
described under **High availability (clustering)** above (server-side
routing makes it transparent to the `neo4j://` driver either way) — that
isn't what `ingress.tf` sets up, since it's solving a different problem
than Bolt-over-WebSocket tunneling. Say the word if that's actually what
you want and I'll wire that up instead/as well.

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

**Local validation:** there's no local emulator for AKS/Azure itself, but
`local-dev/` has a `kind`-based harness that validates the Kubernetes/
Helm/Istio layer (chart values, taints/tolerations, clustering, Istio
`Gateway`/`VirtualService`) against a real local Kubernetes API server —
see `local-dev/README.md` for what it does and doesn't prove, and its own
caveats about not having been run end-to-end in this sandbox either (no
Docker daemon here).

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
- `neo4j-helm-cli.tf`'s rendered `helm upgrade --install ...` command was
  built and printed with real sample values in Python to confirm the flag
  ordering/quoting is sane; the `local-exec`/`null_resource` mechanics
  themselves weren't run end-to-end (no `helm`/cluster in this sandbox).
- The chart repo's actual URL structure (`<repo>/index.yaml`, and that its
  `urls:` entries point at `github.com/neo4j/helm-charts/releases/download/...`
  rather than staying under `helm.neo4j.com`) was confirmed by fetching the
  same index content mirrored at
  `raw.githubusercontent.com/neo4j/helm-charts/master/index.yaml` — direct
  requests to `helm.neo4j.com` and `github.com` itself were both blocked
  in this sandbox's network policy, consistent with what was reported
  about the target enterprise network, so this was checked via the one
  path (`raw.githubusercontent.com`) that was reachable, not guessed.
- The existence and purpose of `neo4j-admin`, `neo4j-headless-service`,
  `neo4j-persistent-volume`, `neo4j-docker-desktop-pv`, and
  `neo4j-reverse-proxy` were confirmed by fetching each chart's
  `Chart.yaml`/`values.yaml` directly from `neo4j/helm-charts` (not
  guessed from the directory names) — `neo4j-admin` in particular reads
  as a general admin chart from its name but its `values.yaml` shows it's
  specifically a scheduled backup `CronJob`.
- The nginx `stream {}` module recommendation and the claim that an
  external LB/proxy works transparently with Neo4j's `neo4j://` driver
  scheme via server-side routing were both checked against Neo4j's own
  "Access the Neo4j cluster from outside Kubernetes" operations-manual
  page (fetched directly — see Sources), not asserted from general nginx/
  Bolt knowledge alone.
- `terraform/ingress.tf`'s `helm_release.neo4j_reverse_proxy` values, and
  the `kubectl_manifest` Gateway/VirtualService `yaml_body`s, were
  rendered through Python's `yaml` module the same way as `neo4j.tf`'s, to
  confirm the shape matches: the `neo4j-reverse-proxy` chart's own
  `values.yaml` (`reverseProxy.serviceName`/`namespace`/`nodeSelector`/
  `tolerations`/`ingress.enabled`); and Istio's own `Gateway`/
  `VirtualService` API shape (`spec.selector`/`spec.servers[].port,tls,hosts`
  for Gateway, `spec.hosts`/`spec.gateways`/`spec.http[].route[].destination.host,port`
  for VirtualService), checked against Istio's own config reference docs
  (see Sources), not guessed.
- The `<neo4j.name>-lb-neo4j` Service name used for `reverseProxy.serviceName`
  matches the literal example in Neo4j's own "Access outside Kubernetes"
  doc. The reverse-proxy chart's own generated Service name
  (`<release>-reverseproxy-service`, used in the VirtualService's
  `destination.host`) was derived from its `templates/ingress.yaml` and
  `templates/_helpers.tpl` (fetched directly — both reference
  `{{ include "neo4j.reverseProxy.fullname" . }}-reverseproxy-service`) —
  **not directly confirmed**, since this sandbox's network couldn't fetch
  the chart's `templates/service.yaml` (guessed several plausible
  filenames, all 404); double-check the actual Service name/port after a
  real `helm install` before assuming the `VirtualService` in
  `ingress.tf` is exactly right.
- That `reverseProxy.ingress.enabled: false` still leaves the chart's
  Service (as opposed to just its Ingress) in place is inferred from the
  template only wrapping the `Ingress` `kind` in that conditional, not
  independently confirmed against the Service template for the same
  reason above.
- `gavinbunney/kubectl`'s `kubectl_manifest` (not a HashiCorp provider)
  was used because the mainline `hashicorp/kubernetes` provider has no
  generic resource for arbitrary CRDs like Istio's — this is the
  established community pattern for exactly this, not an untested choice,
  but wasn't applied against a real cluster in this sandbox (no live AKS,
  and `helm.neo4j.com`/`istio.io`/`github.com` were all unreachable here —
  see the chart-repo-access note above).
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
- [Configuring the Neo4j Helm chart repository — Operations Manual](https://github.com/neo4j/docs-operations/blob/main/modules/ROOT/pages/kubernetes/helm-charts-setup.adoc)
- [Access the Neo4j cluster from outside Kubernetes — Operations Manual](https://github.com/neo4j/docs-operations/blob/main/modules/ROOT/pages/kubernetes/quickstart-cluster/access-outside-k8s.adoc)
- [neo4j/helm-charts repo — chart index](https://raw.githubusercontent.com/neo4j/helm-charts/master/index.yaml) and [Chart.yaml/values.yaml for neo4j-reverse-proxy, neo4j-admin, neo4j-headless-service, neo4j-persistent-volume, neo4j-docker-desktop-pv](https://github.com/neo4j/helm-charts/tree/dev)
- [AKS system node pool restrictions (`only_critical_addons_enabled`) — Terraform `azurerm_kubernetes_cluster` docs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster)
- [Istio Gateway configuration reference](https://istio.io/latest/docs/reference/config/networking/gateway/)
- [Istio VirtualService configuration reference](https://istio.io/latest/docs/reference/config/networking/virtual-service/)
- [kubectl_manifest (gavinbunney/kubectl Terraform provider docs)](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest)
- [azurerm_kubernetes_cluster (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster)
- [azurerm_kubernetes_cluster_node_pool (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool)
- [azurerm_key_vault (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault)
- [kubernetes_pod_disruption_budget_v1 (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/pod_disruption_budget_v1)
