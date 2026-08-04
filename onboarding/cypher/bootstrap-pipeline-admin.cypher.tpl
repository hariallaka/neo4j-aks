// bootstrap-pipeline-admin.cypher.tpl
//
// One-time bootstrap for OIDC-only authentication (see the main README's
// "OIDC-only authentication" section): creates a Neo4j user for the
// onboarding pipeline's OWN Entra ID identity -- a dedicated app
// registration/service principal, distinct from both the Neo4j SSO app
// registration (neo4j_oidc_client_id) and any tenant identity -- linked via
// the oidc-azure auth provider, and grants it Neo4j's built-in `admin`
// role (full DBMS privileges: CREATE DATABASE, CREATE ROLE, CREATE USER,
// GRANT ROLE, etc. across every tenant). The tenant-scoped `_admin` role
// onboard-tenant.cypher.tpl creates is NOT enough for this -- it's
// deliberately confined to one tenant's database (see that template's
// comments) -- the pipeline needs to administer *any* tenant.
//
// Run via `render-and-run.sh bootstrap-pipeline-admin`, which always uses
// the native admin credential (NEO4J_ADMIN_USER/PASSWORD) regardless of
// NEO4J_AUTH_MODE -- this statement is what authenticating via OIDC will
// eventually depend on, so it can't itself depend on OIDC already working.
// It MUST run while native auth is still enabled
// (neo4j_disable_native_auth = false). Required rollout order:
//   1. Configure OIDC (neo4j_oidc_client_id set), native auth still on.
//   2. Run this bootstrap once.
//   3. Verify the pipeline can authenticate via OIDC
//      (NEO4J_AUTH_MODE=oidc) end to end.
//   4. Only then set neo4j_disable_native_auth = true and re-apply.
//
// Idempotent: safe to re-run (CREATE USER ... IF NOT EXISTS).
//
// Placeholders (written without "$" so envsubst doesn't touch this comment):
//   PIPELINE_ADMIN_USER       Neo4j user name for the pipeline's identity.
//   PIPELINE_ENTRA_OBJECT_ID  Object ID of the pipeline's own Entra app
//                             registration/service principal (its Object
//                             ID, not its Application/Client ID -- must
//                             match the `sub`/`oid` claim in tokens it
//                             requests, same as tenant identity onboarding).

CREATE USER `${PIPELINE_ADMIN_USER}` IF NOT EXISTS
SET AUTH 'oidc-azure' {SET ID '${PIPELINE_ENTRA_OBJECT_ID}'};

GRANT ROLE admin TO `${PIPELINE_ADMIN_USER}`;
