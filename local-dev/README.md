# Local validation harness

Validates the **Kubernetes/Helm/Istio layer** of `terraform/neo4j.tf` and
`terraform/ingress.tf` against a local [kind](https://kind.sigs.k8s.io/)
cluster: same node taints/labels (`workloadsize=small|large`), the same
`neo4j` chart with equivalent values, and the same Istio TCP `Gateway`/
`VirtualService` shape (plain passthrough to `services.neo4j` -- no
separate backend pod).

## What this does and doesn't prove

There is no local emulator for AKS itself. This harness **cannot** validate:

- The `azurerm_*` resources (the AKS cluster, node pools as real VMSS, Key
  Vault, Azure LoadBalancer, Azure AD RBAC, Microsoft Defender).
- Anything Azure-specific in `neo4j.tf`'s config (the OIDC/Entra block is
  deliberately omitted from `values/neo4j-values.yaml`).

For that layer, the closest thing to validation is `cd terraform &&
terraform init && terraform validate` (catches HCL/type errors) and
`terraform plan` against real Azure credentials (catches everything else) —
neither was runnable in the sandbox that authored this repo's Terraform,
since it had no network path to `registry.terraform.io`.

What this harness **does** validate: that the chart values Terraform
computes are structurally correct and the chart actually accepts them
(clustering forms, pods schedule where the taints/selectors say they
should, Istio accepts the `Gateway`/`VirtualService` shape and routes to
`services.neo4j`). The values files here are
**hand-mirrored** from `terraform/*.tf`, not generated from it — see each
file's header comment for the specific deviations (smaller resource
requests, `ClusterIP` instead of `LoadBalancer`, `eval` license instead of
a real one, a local-only StorageClass). If you change `terraform/neo4j.tf`
or `terraform/ingress.tf`, update the mirrored values here too, or this
harness will silently validate a stale config.

## Prerequisites

- Docker (or Colima/Podman with a Docker-compatible socket), actually running.
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- `kubectl`
- `helm` v3
- [`istioctl`](https://istio.io/latest/docs/setup/getting-started/) —
  optional; without it, the Gateway/VirtualService step still runs but is
  expected to fail with `no matches for kind Gateway` (Istio's CRDs aren't
  installed), which is itself a useful signal that the manifests are at
  least being applied correctly up to that point.

None of these were available in the sandbox that wrote this script — it
was authored against the Terraform config and each chart's own
`values.yaml`/templates (fetched directly, not guessed — see the main
README's Testing section for what was cross-checked), but **not executed
end-to-end**. Run it yourself and report back what breaks.

## Usage

```bash
cd local-dev
./validate.sh up       # create the cluster, install everything, verify
./validate.sh status   # re-check an existing run
./validate.sh down     # tear down the kind cluster
```

Point at an internal Helm mirror the same way `terraform.tfvars`'s
`neo4j_helm_repo_url` would, if `helm.neo4j.com` isn't reachable from
where you're running this:

```bash
NEO4J_HELM_REPO_URL=https://your-internal-mirror/neo4j ./validate.sh up
```

Skip the Istio half (just validate the `neo4j` cluster chart layer):

```bash
SKIP_ISTIO=1 ./validate.sh up
```

## Known gaps / things to sanity-check on first run

- The `cypher-shell` pod name used to check `SHOW SERVERS` (`neo4j-aks-local-0-0`)
  is a guess at the chart's StatefulSet/pod naming — if it's wrong, the
  script warns rather than fails; check `kubectl -n neo4j get pods` and
  adjust `validate.sh` if needed.
- `terraform/neo4j.tf`'s `kubernetes_pod_disruption_budget_v1` isn't
  reproduced here (it's a plain Kubernetes resource, not part of the
  chart) — `validate.sh` only prints whatever PDBs the chart itself
  creates, which may be none; create one by hand with `kubectl apply` if
  you want to validate that shape too.
- `istioctl install --set profile=demo` installs a full demo-profile Istio
  (ingress gateway, egress gateway, etc.) — heavier than the "minimal"
  profile terraform/ingress.tf's production assumption (Istio already
  installed by someone else) implies. Fine for local validation; don't
  read anything about resource sizing into it.
