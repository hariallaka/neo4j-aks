// offboard-identity.cypher.tpl
//
// Removes one identity's access without touching the tenant's database,
// roles, or any other identity's access to it. Does NOT drop the tenant
// database itself -- decommissioning a whole tenant is a separate,
// deliberately-not-automated action (see README).
//
// Rendered by ../scripts/render-and-run.sh.
//
// Placeholders (written without "$" so envsubst doesn't touch this comment):
//   IDENTITY_USER   Neo4j user name created by onboard-tenant.cypher.tpl
//                   for this identity.

DROP USER `${IDENTITY_USER}` IF EXISTS;
