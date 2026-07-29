#!/usr/bin/env bash
# render-and-run.sh
#
# Renders onboard-tenant.cypher.tpl (or offboard-identity.cypher.tpl) with
# the given parameters and runs it against Neo4j via cypher-shell. Used
# directly by the Azure DevOps steps template
# (../../azure-pipelines/templates/steps-onboard-tenant.yml), and safe to
# run by hand for local testing/dry runs.
#
# Required env vars (the pipeline sources these from a Key Vault-linked
# variable group -- see azure-pipelines/README.md):
#   NEO4J_BOLT_URI       e.g. neo4j+s://neo4j-aks.internal:7687
#   NEO4J_ADMIN_USER     native admin user, e.g. the provisioning service account
#   NEO4J_ADMIN_PASSWORD native admin password (from Key Vault secret neo4j-admin-password)
#
# Usage:
#   render-and-run.sh onboard  <tenant> <access-level> <identity-name> <entra-object-id> [--dry-run]
#   render-and-run.sh offboard <identity-name> [--dry-run]
#
# access-level is one of: reader, writer, admin
# --dry-run renders the Cypher and prints it without executing anything.

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

run_cypher() {
  local rendered="$1" dry_run="$2"
  echo "---- rendered Cypher ----"
  cat "${rendered}"
  echo "--------------------------"

  if [[ "${dry_run}" == "true" ]]; then
    echo "(dry run: not executed)"
    return
  fi

  : "${NEO4J_BOLT_URI:?NEO4J_BOLT_URI must be set}"
  : "${NEO4J_ADMIN_USER:?NEO4J_ADMIN_USER must be set}"
  : "${NEO4J_ADMIN_PASSWORD:?NEO4J_ADMIN_PASSWORD must be set}"

  cypher-shell -a "${NEO4J_BOLT_URI}" \
    -u "${NEO4J_ADMIN_USER}" -p "${NEO4J_ADMIN_PASSWORD}" \
    --format plain -f "${rendered}"
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

  *)
    echo "usage: $0 onboard <tenant> <access-level> <identity-name> <entra-object-id> [--dry-run]" >&2
    echo "       $0 offboard <identity-name> [--dry-run]" >&2
    exit 1
    ;;
esac
