# neo4j-aks

Terraform that provisions an Azure Kubernetes Service (AKS) cluster and
deploys Neo4j onto it via the official Neo4j Helm chart, in one `terraform
apply`.

## What it creates

- `terraform/aks.tf` — a resource group and an AKS cluster
  (`azurerm_kubernetes_cluster`, system-assigned identity, a single default
  node pool).
- `terraform/neo4j.tf` — a `neo4j` namespace, a generated password
  (`random_password`), and a `helm_release` of the official Neo4j chart
  (`neo4j/helm-charts`, repo `https://helm.neo4j.com/neo4j`, chart name
  `neo4j`) into that cluster, configured for:
  - Community edition by default (`neo4j_edition`/`neo4j_accept_license_agreement`
    variables switch to Enterprise).
  - A dynamically provisioned data volume (`volumes.data.mode = "dynamic"`)
    against an explicit StorageClass (`managed-csi` by default — one of the
    two StorageClasses AKS ships out of the box).
  - Neo4j exposed outside the cluster via an Azure LoadBalancer
    (`services.neo4j.spec.type = "LoadBalancer"`) — switch to `ClusterIP`
    if you'd rather front it with your own ingress.
- The `kubernetes`/`helm` Terraform providers are configured directly from
  the AKS cluster's own `kube_config` output, so there's no separate
  `az aks get-credentials` step needed before `apply`.

This is a single standalone Neo4j instance, not a Neo4j causal cluster —
the chart supports clustering (see `neo4j.minimumClusterSize` and related
values in the chart's `values.yaml`), but wiring up multiple
`helm_release`s for that is out of scope here.

## Prerequisites

- An Azure subscription, authenticated via `az login` or an
  `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID`
  service principal.
- If installing Neo4j **Enterprise** edition, a Neo4j license agreement (or
  set `neo4j_accept_license_agreement = "eval"` to use the evaluation
  license) — see [neo4j.com/licensing](https://neo4j.com/licensing/).

## Usage

```bash
cd terraform
terraform init
cp terraform.tfvars.example terraform.tfvars   # then edit as needed
terraform apply -var-file="terraform.tfvars"
```

Get the generated Neo4j password and a usable kubeconfig afterwards:

```bash
terraform output -raw neo4j_initial_password
terraform output -raw kube_config > kubeconfig
KUBECONFIG=./kubeconfig kubectl -n neo4j get svc   # find the LoadBalancer's external IP
```

## Testing

This was written and formatted in a sandbox whose network egress policy
blocks `registry.terraform.io` (confirmed via a 403 on `terraform init` —
not something to route around per that policy), and there's no live Azure
subscription to apply against either. Given that, what was actually done:

- `terraform fmt -check -diff -recursive` passes clean on every `.tf` file.
- The Neo4j chart's repo URL, chart name, and every Helm value used here
  (`neo4j.name`, `neo4j.edition`, `neo4j.acceptLicenseAgreement`,
  `neo4j.password`, `neo4j.resources.*`, `volumes.data.mode` and its
  `dynamic.*` sub-fields, `services.neo4j.spec.type`) were checked against
  the chart's actual `values.yaml` in
  [neo4j/helm-charts](https://github.com/neo4j/helm-charts/blob/dev/neo4j/values.yaml)
  (the current, actively maintained chart — not the deprecated
  `neo4j-contrib/neo4j-helm`), not guessed.
- The `azurerm_kubernetes_cluster` shape (identity block, default node pool,
  `kube_config` attribute used to feed the `kubernetes`/`helm` providers) is
  the standard pattern documented by the `hashicorp/azurerm` provider.

Before relying on this in production: run `terraform init && terraform
validate` yourself where `registry.terraform.io` is reachable, and
`terraform plan`/`apply` against a real Azure subscription — ideally
starting in a disposable resource group.

## Sources

- [neo4j/helm-charts values.yaml](https://github.com/neo4j/helm-charts/blob/dev/neo4j/values.yaml)
- [Neo4j Kubernetes deployment — Operations Manual](https://neo4j.com/docs/operations-manual/current/kubernetes/introduction/)
- [azurerm_kubernetes_cluster (Terraform Registry)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster)
