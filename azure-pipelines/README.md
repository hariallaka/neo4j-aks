# Azure DevOps pipelines

On-demand (no CI/PR trigger) pipelines that run `../onboarding/scripts/render-and-run.sh`
against the shared Neo4j DBMS.

## Files

```
onboard-tenant-pipeline.yml        Top-level pipeline: onboard a tenant/identity.
offboard-identity-pipeline.yml     Top-level pipeline: remove one identity.
templates/
  steps-onboard-tenant.yml         Reusable steps: install cypher-shell, run render-and-run.sh onboard.
  steps-offboard-identity.yml      Reusable steps: install cypher-shell, run render-and-run.sh offboard.
```

## One-time Azure DevOps setup

1. **Agent pool**: these pipelines target a named self-hosted pool
   (`self-hosted-neo4j` in the YAML — rename to match yours). A
   Microsoft-hosted agent generally can't reach a private AKS
   LoadBalancer/VNet, so use a self-hosted agent with network line-of-sight
   to the Neo4j Bolt endpoint (e.g. one deployed inside the same VNet, or
   peered to it).
2. **Variable group**: create a variable group named
   `neo4j-onboarding-secrets` (Azure DevOps -> Pipelines -> Library -> +
   Variable group), enable "Link secrets from an Azure key vault as
   variables", point it at the `kv-neo4j-aks` Key Vault from `terraform/`,
   and select the `neo4j-admin-password` secret, exposing it as
   `NEO4J_ADMIN_PASSWORD`. The service connection used for that link needs
   at least `Key Vault Secrets User` on that vault.
3. Edit `NEO4J_BOLT_URI` and `NEO4J_ADMIN_USER` in both pipeline YAML files
   to match your deployment (`NEO4J_ADMIN_USER` should be a native admin
   account dedicated to this pipeline, not someone's personal login).
4. Import both pipelines into Azure DevOps (Pipelines -> New pipeline ->
   Existing Azure Pipelines YAML file), pointing at
   `azure-pipelines/onboard-tenant-pipeline.yml` and
   `azure-pipelines/offboard-identity-pipeline.yml` respectively.

## Running

Pipelines -> select the pipeline -> Run pipeline, fill in the parameters
(tenant, access level, identity name, Entra Object ID). **Dry run defaults
to `true`** — leave it on for your first run against a new tenant/identity
combination and check the logged Cypher before flipping it off and running
again for real.

## Testing

These YAML files were parsed with Python's `yaml.safe_load` to confirm
they're syntactically valid. They have not been run against a real Azure
DevOps project (no such environment was available); the underlying
`render-and-run.sh` logic they invoke was tested directly (see the main
README's Testing section) with a stub `cypher-shell`, which is the part
most likely to have real bugs.
