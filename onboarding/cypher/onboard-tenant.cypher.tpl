// onboard-tenant.cypher.tpl
//
// Onboards one usecase/tenant onto the shared Neo4j Enterprise DBMS:
// creates its database (if it doesn't exist), its three standard roles
// scoped to that database only, and links one Entra ID identity (a
// managed identity or service principal's Object ID) to a Neo4j user via
// the oidc-azure auth provider, then grants it the requested role.
//
// Run once per (tenant, identity) pair -- re-running for the same tenant
// with a different identity/role is safe (CREATE ... IF NOT EXISTS) and is
// exactly how you add a second identity to an already-onboarded tenant.
//
// Rendered by ../scripts/render-and-run.sh, which substitutes the
// placeholders below (shell-style variable references) via envsubst
// before piping this file into cypher-shell. Every value is validated by
// that script first (see its comments) -- do not run this template
// directly with unvalidated input. All identifiers are backtick-quoted so
// tenant/identity names containing hyphens (common in Azure naming
// conventions) parse correctly.
//
// NOTE: the placeholder names below are written without their shell "$"
// prefix, on purpose -- with it, envsubst would substitute them right here
// in this comment too.
//
// Placeholders:
//   TENANT_DB        Neo4j database name for this tenant/usecase.
//   ROLE_READER       Reader role name for this tenant (usually TENANT_DB_reader).
//   ROLE_WRITER       Writer role name for this tenant (usually TENANT_DB_writer).
//   ROLE_ADMIN        Admin role name for this tenant (usually TENANT_DB_admin).
//   IDENTITY_USER     Neo4j user name to create/reuse for this identity.
//   ENTRA_OBJECT_ID   Value that must match the `sub` claim (or whatever
//                     dbms.security.oidc.azure.claims.username is set to)
//                     in this identity's Entra-issued access tokens.
//   GRANTED_ROLE      Which of the three roles above to grant: the
//                     literal value of ROLE_READER, ROLE_WRITER, or
//                     ROLE_ADMIN, chosen by the pipeline based on the
//                     requested access level.

// 1. Create the tenant's database if it doesn't already exist.
CREATE DATABASE `${TENANT_DB}` IF NOT EXISTS;

// 2. Reader: can see and read everything in this tenant's database only.
CREATE ROLE `${ROLE_READER}` IF NOT EXISTS;
GRANT ACCESS ON DATABASE `${TENANT_DB}` TO `${ROLE_READER}`;
GRANT MATCH {*} ON GRAPH `${TENANT_DB}` NODE * TO `${ROLE_READER}`;
GRANT MATCH {*} ON GRAPH `${TENANT_DB}` RELATIONSHIP * TO `${ROLE_READER}`;

// 3. Writer: reader privileges plus data writes. No schema/index/database
//    administration.
CREATE ROLE `${ROLE_WRITER}` IF NOT EXISTS;
GRANT ACCESS ON DATABASE `${TENANT_DB}` TO `${ROLE_WRITER}`;
GRANT MATCH {*} ON GRAPH `${TENANT_DB}` NODE * TO `${ROLE_WRITER}`;
GRANT MATCH {*} ON GRAPH `${TENANT_DB}` RELATIONSHIP * TO `${ROLE_WRITER}`;
GRANT WRITE ON GRAPH `${TENANT_DB}` TO `${ROLE_WRITER}`;

// 4. Admin: writer privileges plus schema/index/constraint management and
//    start/stop of this tenant's own database. Deliberately NOT granted
//    any DBMS-wide privilege (can't create other tenants' databases, can't
//    manage users/roles outside its own three).
CREATE ROLE `${ROLE_ADMIN}` IF NOT EXISTS;
GRANT ACCESS ON DATABASE `${TENANT_DB}` TO `${ROLE_ADMIN}`;
GRANT MATCH {*} ON GRAPH `${TENANT_DB}` NODE * TO `${ROLE_ADMIN}`;
GRANT MATCH {*} ON GRAPH `${TENANT_DB}` RELATIONSHIP * TO `${ROLE_ADMIN}`;
GRANT WRITE ON GRAPH `${TENANT_DB}` TO `${ROLE_ADMIN}`;
GRANT START ON DATABASE `${TENANT_DB}` TO `${ROLE_ADMIN}`;
GRANT STOP ON DATABASE `${TENANT_DB}` TO `${ROLE_ADMIN}`;
GRANT INDEX MANAGEMENT ON DATABASE `${TENANT_DB}` TO `${ROLE_ADMIN}`;
GRANT CONSTRAINT MANAGEMENT ON DATABASE `${TENANT_DB}` TO `${ROLE_ADMIN}`;

// 5. Link the identity: authenticates via its Entra-issued token
//    (oidc-azure), authorized natively via the GRANT ROLE below.
//    Requires dbms.security.require_local_user=true and the oidc-azure
//    provider configured (see terraform/neo4j.tf) -- both are only applied
//    once terraform.tfvars sets neo4j_oidc_client_id.
CREATE USER `${IDENTITY_USER}` IF NOT EXISTS
SET HOME DATABASE '${TENANT_DB}'
SET AUTH 'oidc-azure' {SET ID '${ENTRA_OBJECT_ID}'};

// 6. Grant the requested access level.
GRANT ROLE `${GRANTED_ROLE}` TO `${IDENTITY_USER}`;
