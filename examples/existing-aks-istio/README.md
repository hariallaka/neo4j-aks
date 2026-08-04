# Example: deploy Neo4j onto an existing AKS + Istio cluster

A self-contained Terraform example that deploys a Neo4j Enterprise cluster
onto an **AKS cluster you already have**, with **Istio already installed**
on it. It's a trimmed illustration of the patterns in the main
[`../../terraform`](../../terraform) stack (`neo4j.tf`/`ingress.tf`), not
a replacement for it — see **What this deliberately doesn't do** below.

## Assumptions

- An AKS cluster already exists, and you have `kubectl`/Terraform access
  to it (via a kubeconfig — `az aks get-credentials` writes one).
- Istio (istiod + an ingress gateway) is already installed and running in
  that cluster. This example only creates Neo4j's own `Gateway`/
  `VirtualService` routing objects — it does not install Istio.
- You have (or will get, for real use) a Neo4j Enterprise license, or
  you're fine with `neo4j_accept_license_agreement = "eval"` for a
  non-production trial — see [neo4j.com/licensing](https://neo4j.com/licensing/).

## What this deploys

- `var.neo4j_cluster_size` (default `3`) Neo4j cluster members, each its
  own Helm release/pod/PVC — same one-release-per-member pattern as the
  main stack, for real HA (fault tolerance `M = 2F+1`).
- A cluster-wide `PodDisruptionBudget` (when `neo4j_cluster_size >= 3`).
- If `istio_gateway_enabled` (default `true`): an Istio `Gateway` binding
  to your **existing** ingress gateway workload (matched by
  `istio_ingress_gateway_selector`) and a `VirtualService` doing plain TCP
  passthrough to Neo4j's Service on Bolt (7687) and Browser HTTP (7474).
  No HTTP/WebSocket tunneling — this doesn't help if end users can only
  reach 80/443, only if they can reach those ports directly through your
  gateway. See the main README's Istio section for why, and what to add
  if you need that (Neo4j's own `neo4j-reverse-proxy` chart).

## What this deliberately doesn't do

Unlike `../../terraform`, this example has **no `azurerm` provider at
all** — it doesn't create the AKS cluster, node pools, Key Vault, or
Istio itself, and it doesn't set up multi-tenant onboarding, OIDC/Entra
auth, or the `helm_cli`/proxy-mirror options. It's meant to be a minimal,
readable starting point for "I already have AKS + Istio, show me how to
get Neo4j running on it" — see `../../terraform` and the main README for
the full production stack (multi-database multi-tenancy, Entra SSO,
OIDC-only auth, the AKS cluster/node pools/Key Vault themselves).

## Usage

```bash
# Point kubectl/this example at your cluster first, if you haven't:
az aks get-credentials --name <your-cluster> --resource-group <your-rg>

cd examples/existing-aks-istio
terraform init
cp terraform.tfvars.example terraform.tfvars   # then edit as needed
terraform apply -var-file="terraform.tfvars"
```

Get the generated password and confirm things came up:

```bash
terraform output -raw neo4j_initial_password
kubectl -n neo4j get pods
kubectl -n neo4j get gateway,virtualservice   # if istio_gateway_enabled
```

## Testing

This wasn't run against a real cluster — the sandbox that wrote it had no
`terraform`/`kubectl`/`helm`/network access to any of the registries
involved (see the main README's Testing section for the same constraint
on the primary stack). What was checked:

- `main.tf`'s Helm values and `kubectl_manifest` `yaml_body`s were
  rendered through Python's `yaml` module to confirm the shape matches
  the `neo4j` chart's own `values.yaml` and Istio's own TCP routing
  sample (`istio/istio`'s `samples/tcp-echo`) — same checks already done
  for the equivalent code in `../../terraform/neo4j.tf`/`ingress.tf`, not
  re-derived from scratch.
- All `.tf` files here have balanced braces/parens (checked with a small
  Python script, in lieu of `terraform validate`, which needs
  `registry.terraform.io` — unreachable in this sandbox).
- Run `terraform init && terraform validate` yourself where the registry
  is reachable, then `terraform plan`/`apply` against your real cluster,
  before trusting this further.
