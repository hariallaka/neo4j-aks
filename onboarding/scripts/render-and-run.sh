#!/usr/bin/env bash
# render-and-run.sh
#
# Renders a Cypher template with the given parameters and runs it against
# Neo4j. Used directly by the Azure DevOps steps templates
# (../../azure-pipelines/templates/steps-*.yml), and safe to run by hand
# for local testing/dry runs.
#
# How the rendered Cypher actually gets executed depends on NEO4J_AUTH_MODE:
#   native (default) -- cypher-shell with NEO4J_ADMIN_USER/NEO4J_ADMIN_PASSWORD.
#   oidc              -- run_cypher_oidc.py, authenticating as the pipeline's
#                        own Entra service principal via bearer token. Only
#                        usable once that identity has been bootstrapped
#                        (see the `bootstrap-pipeline-admin` action below)
#                        and works whether or not native auth is still
#                        enabled server-side -- but is REQUIRED once
#                        neo4j_disable_native_auth = true, since native
#                        credentials stop being accepted at all at that
#                        point. See the main README's "OIDC-only
#                        authentication" section for the full picture.
#
# Required env vars (the pipeline sources these from a Key Vault-linked
# variable group -- see azure-pipelines/README.md):
#   NEO4J_BOLT_URI            e.g. neo4j+s://neo4j-aks.internal:7687
#   NEO4J_AUTH_MODE           "native" (default if unset) or "oidc"
#   -- native mode:
#   NEO4J_ADMIN_USER          native admin user, e.g. the provisioning service account
#   NEO4J_ADMIN_PASSWORD      native admin password (from Key Vault secret neo4j-admin-password)
#   -- oidc mode (see run_cypher_oidc.py's own docstring for detail):
#   ENTRA_TENANT_ID           Entra tenant (Directory) ID
#   PIPELINE_CLIENT_ID        the pipeline's own app registration/service principal
#   PIPELINE_CLIENT_SECRET    that service principal's secret (from Key Vault
#                             secret neo4j-pipeline-client-secret, if terraform
#                             was given neo4j_pipeline_client_secret)
#   NEO4J_OIDC_AUDIENCE_SCOPE e.g. api://<neo4j-sso-client-id>/.default
#
# Usage:
#   render-and-run.sh onboard  <tenant> <access-level> <identity-name> <entra-object-id> [--dry-run]
#   render-and-run.sh offboard <identity-name> [--dry-run]
#   render-and-run.sh bootstrap-pipeline-admin <pipeline-admin-user> <pipeline-entra-object-id> [--dry-run]
#
# access-level is one of: reader, writer, admin
# --dry-run renders the Cypher and prints it without executing anything.
# bootstrap-pipeline-admin always uses native auth regardless of
# NEO4J_AUTH_MODE -- see bootstrap-pipeline-admin.cypher.tpl for why.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CYPHER_DIR="$(cd "${HERE}/../cypher" && pwd)"

# Deliberately strict: these values get substituted directly into Cypher
# text (envsubst, not a parameterized query -- Neo4j's admin commands don't
# accept parameters for identifiers), so anything that isn't a plain
# alphanumeric/underscore/hyphen name is rejected before it ever reaches a
# template. The templates backtick-quote every identifier built from these
# values, but backticks/quotes/semicolons are still refused here -- a name
# that could close a backtick-quoted identifier early must never reach
# envsubst.
NAME_RE='^[a-zA-Z][a-zA-Z0-9_-]{0,62}$'
# Entra Object IDs are GUIDs.
GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

require_match() {
  local value="$1" pattern="$2" label="$3"
  if [[ ! "${value}" =~ ${pattern} ]]; then
    echo "error: ${label} '${value}' does not match required pattern ${pattern}" >&2
    exit 1
  fi
}

# force_native=true (only bootstrap-pipeline-admin sets this) ignores
# NEO4J_AUTH_MODE and always runs via native cypher-shell -- see
# bootstrap-pipeline-admin.cypher.tpl for why that one action can't use
# OIDC auth (it's what makes OIDC auth possible in the first place).
run_cypher() {
  local rendered="$1" dry_run="$2" force_native="${3:-false}"
  echo "---- rendered Cypher ----"
  cat "${rendered}"
  echo "--------------------------"

  if [[ "${dry_run}" == "true" ]]; then
    echo "(dry run: not executed)"
    return
  fi

  : "${NEO4J_BOLT_URI:?NEO4J_BOLT_URI must be set}"

  local auth_mode="${NEO4J_AUTH_MODE:-native}"
  if [[ "${force_native}" == "true" ]]; then
    auth_mode="native"
  fi

  case "${auth_mode}" in
    native)
      : "${NEO4J_ADMIN_USER:?NEO4J_ADMIN_USER must be set}"
      : "${NEO4J_ADMIN_PASSWORD:?NEO4J_ADMIN_PASSWORD must be set}"
      cypher-shell -a "${NEO4J_BOLT_URI}" \
        -u "${NEO4J_ADMIN_USER}" -p "${NEO4J_ADMIN_PASSWORD}" \
        --format plain -f "${rendered}"
      ;;
    oidc)
      python3 "${HERE}/run_cypher_oidc.py" "${rendered}"
      ;;
    *)
      echo "error: NEO4J_AUTH_MODE must be 'native' or 'oidc' (got '${auth_mode}')" >&2
      exit 1
      ;;
  esac
}

action="${1:-}"
case "${action}" in
  onboard)
    tenant="${2:?tenant name required}"
    access_level="${3:?access level required (reader|writer|admin)}"
    identity_user="${4:?identity user name required}"
    entra_object_id="${5:?Entra object ID required}"
    dry_run="false"
    [[ "${6:-}" == "--dry-run" ]] && dry_run="true"

    require_match "${tenant}" "${NAME_RE}" "tenant"
    require_match "${identity_user}" "${NAME_RE}" "identity user"
    require_match "${entra_object_id}" "${GUID_RE}" "Entra object ID"
    case "${access_level}" in
      reader|writer|admin) ;;
      *) echo "error: access level must be reader, writer, or admin" >&2; exit 1 ;;
    esac

    export TENANT_DB="${tenant}"
    export ROLE_READER="${tenant}_reader"
    export ROLE_WRITER="${tenant}_writer"
    export ROLE_ADMIN="${tenant}_admin"
    export IDENTITY_USER="${identity_user}"
    export ENTRA_OBJECT_ID="${entra_object_id}"
    case "${access_level}" in
      reader) export GRANTED_ROLE="${ROLE_READER}" ;;
      writer) export GRANTED_ROLE="${ROLE_WRITER}" ;;
      admin)  export GRANTED_ROLE="${ROLE_ADMIN}" ;;
    esac

    rendered="$(mktemp)"
    envsubst < "${CYPHER_DIR}/onboard-tenant.cypher.tpl" > "${rendered}"
    run_cypher "${rendered}" "${dry_run}"
    ;;

  offboard)
    identity_user="${2:?identity user name required}"
    dry_run="false"
    [[ "${3:-}" == "--dry-run" ]] && dry_run="true"

    require_match "${identity_user}" "${NAME_RE}" "identity user"

    export IDENTITY_USER="${identity_user}"

    rendered="$(mktemp)"
    envsubst < "${CYPHER_DIR}/offboard-identity.cypher.tpl" > "${rendered}"
    run_cypher "${rendered}" "${dry_run}"
    ;;

  bootstrap-pipeline-admin)
    pipeline_admin_user="${2:?pipeline admin user name required}"
    pipeline_entra_object_id="${3:?pipeline Entra object ID required}"
    dry_run="false"
    [[ "${4:-}" == "--dry-run" ]] && dry_run="true"

    require_match "${pipeline_admin_user}" "${NAME_RE}" "pipeline admin user"
    require_match "${pipeline_entra_object_id}" "${GUID_RE}" "pipeline Entra object ID"

    export PIPELINE_ADMIN_USER="${pipeline_admin_user}"
    export PIPELINE_ENTRA_OBJECT_ID="${pipeline_entra_object_id}"

    rendered="$(mktemp)"
    envsubst < "${CYPHER_DIR}/bootstrap-pipeline-admin.cypher.tpl" > "${rendered}"
    run_cypher "${rendered}" "${dry_run}" "true"
    ;;

  *)
    echo "usage: $0 onboard <tenant> <access-level> <identity-name> <entra-object-id> [--dry-run]" >&2
    echo "       $0 offboard <identity-name> [--dry-run]" >&2
    echo "       $0 bootstrap-pipeline-admin <pipeline-admin-user> <pipeline-entra-object-id> [--dry-run]" >&2
    exit 1
    ;;
esac
