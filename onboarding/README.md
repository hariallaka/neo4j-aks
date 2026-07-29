# Onboarding

Scripts and Cypher templates that onboard/offboard a tenant or identity
against the shared Neo4j Enterprise DBMS provisioned by `../terraform`. See
the main README's **Architecture** and **One-time Entra ID setup** sections
for the model these implement.

## Files

```
cypher/
  onboard-tenant.cypher.tpl       CREATE DATABASE + 3 roles + CREATE USER (OIDC-linked) + GRANT ROLE.
  offboard-identity.cypher.tpl    DROP USER for one identity; doesn't touch the tenant's database/roles.
scripts/
  render-and-run.sh               Validates input, renders a template, runs it via cypher-shell.
```

## Usage

```bash
export NEO4J_BOLT_URI=neo4j+s://<your-neo4j-endpoint>:7687
export NEO4J_ADMIN_USER=svc_provisioning      # a native admin account, not an OIDC identity
export NEO4J_ADMIN_PASSWORD=<from Key Vault "neo4j-admin-password">

# Onboard: creates the "acmecorp" database (if new), its 3 roles (if new),
# and grants svc-acmecorp-reader (linked to the given Entra Object ID) the
# reader role.
./scripts/render-and-run.sh onboard acmecorp reader svc-acmecorp-reader 11111111-2222-3333-4444-555555555555

# Add a second identity to the same tenant, as writer:
./scripts/render-and-run.sh onboard acmecorp writer svc-acmecorp-writer 22222222-3333-4444-5555-666666666666

# Remove one identity (doesn't touch the tenant's database/roles/other identities):
./scripts/render-and-run.sh offboard svc-acmecorp-writer
```

Add `--dry-run` to any command to see the rendered Cypher without executing
it.

## Input validation

Tenant names, role-derived names, and identity user names are restricted to
`^[a-zA-Z][a-zA-Z0-9_-]{0,62}$` and Entra Object IDs must be a GUID —
enforced in `render-and-run.sh` before anything is substituted into a
template. This isn't cosmetic: these values are substituted directly into
Cypher text (`envsubst`), not passed as query parameters, because Neo4j's
administration commands (`CREATE DATABASE`/`CREATE ROLE`/`GRANT`) don't
accept parameters for identifiers. The templates backtick-quote every
identifier, but a name that could close a backtick-quoted identifier early
(a backtick, a quote, a semicolon) must never reach `envsubst` in the first
place — hence the regex gate.

## What onboarding does NOT do

- Doesn't create or manage the Entra ID app registration, or assign
  Entra app roles/groups — that's the one-time setup in the main README.
- Doesn't decommission a whole tenant (drop its database/roles). Removing
  a tenant entirely is deliberately not automated here; do it by hand once
  you're sure nothing still depends on it.
- Doesn't manage the native admin credential used to run these scripts —
  that's `terraform/keyvault.tf`'s `neo4j-admin-password` secret.
