# Alternative to helm_release.neo4j in neo4j.tf: installs the same chart,
# with the same values (local.neo4j_helm_values) and the same
# one-release-per-cluster-member topology (local.neo4j_release_names), but
# by shelling out to a locally-installed `helm` binary instead of using the
# Terraform helm provider's own Go SDK. Active only when
# var.neo4j_deployment_method = "helm_cli".
#
# Why this exists: the Terraform helm provider talks to the chart repo
# itself (it doesn't shell out to your local `helm`/proxy config), so if
# your only working path to the chart repo is through a locally-configured
# `helm` (corporate HTTP_PROXY/HTTPS_PROXY/NO_PROXY env vars, an internal
# repo mirror already trusted by your machine's CA bundle, credentials helm
# itself manages, etc.), the native helm_release resource can't necessarily
# reuse that setup. Running the CLI directly can. See the README's
# proxy-cache note for what var.neo4j_helm_repo_url needs to point at.
#
# Trade-off: Terraform only tracks this as an opaque null_resource, not a
# typed Helm release -- it won't detect drift the way helm_release does,
# and `terraform plan` can't show you what would change inside the chart.
# The rendered values file's sha256 is used as a trigger so `terraform
# apply` re-runs `helm upgrade --install` whenever the computed values
# actually change.

resource "local_file" "neo4j_values" {
  for_each = var.neo4j_deployment_method == "helm_cli" ? local.neo4j_release_names : {}

  filename        = "${path.module}/.neo4j-values/${each.value}.yaml"
  content         = yamlencode(local.neo4j_helm_values)
  file_permission = "0600"
}

resource "null_resource" "neo4j_helm_cli" {
  for_each = var.neo4j_deployment_method == "helm_cli" ? local.neo4j_release_names : {}

  triggers = {
    release       = each.value
    namespace     = kubernetes_namespace.neo4j.metadata[0].name
    repo_url      = var.neo4j_helm_repo_url
    chart_version = var.neo4j_helm_chart_version
    values_sha256 = sha256(yamlencode(local.neo4j_helm_values))
  }

  # NEO4J_PASSWORD is passed as an env var (expanded by the shell, not by
  # Terraform) rather than inlined into `command`, so it doesn't show up in
  # `ps`/shell history on the machine running `terraform apply`. It's still
  # stored in Terraform state as part of this resource either way -- same
  # trade-off the set_sensitive block on helm_release.neo4j already accepts
  # (see README: treat Terraform state itself as sensitive).
  provisioner "local-exec" {
    environment = {
      NEO4J_PASSWORD = random_password.neo4j.result
    }
    command = join(" ", compact([
      "helm upgrade --install ${each.value} neo4j",
      "--repo ${var.neo4j_helm_repo_url}",
      var.neo4j_helm_chart_version != "" ? "--version ${var.neo4j_helm_chart_version}" : "",
      "--namespace ${kubernetes_namespace.neo4j.metadata[0].name}",
      "-f ${local_file.neo4j_values[each.key].filename}",
      "--set neo4j.password=$NEO4J_PASSWORD",
      "--wait --timeout 10m",
    ]))
  }

  provisioner "local-exec" {
    when    = destroy
    command = "helm uninstall ${self.triggers.release} --namespace ${self.triggers.namespace} || true"
  }

  depends_on = [
    kubernetes_namespace.neo4j,
    local_file.neo4j_values,
    azurerm_kubernetes_cluster_node_pool.small,
    azurerm_kubernetes_cluster_node_pool.large,
  ]
}
