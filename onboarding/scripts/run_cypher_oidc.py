#!/usr/bin/env python3
"""run_cypher_oidc.py

Runs a rendered Cypher file against Neo4j using bearer-token authentication
(an Entra ID access token, via the pipeline's own service principal and the
client-credentials grant) instead of a native username/password.

Why this exists instead of just using cypher-shell: cypher-shell has no
documented flag for bearer/access-token authentication -- checked directly
against Neo4j's own cypher-shell.adoc (only -u/--username, -p/--password,
and --impersonate are listed there). The neo4j Python driver's
`bearer_auth()` is Neo4j's own documented mechanism for exactly this case
(OIDC service-account/automation access) -- see the Python Driver Manual's
"Advanced connection information" page and Neo4j's own blog post on OIDC
service accounts (both linked from the main README's Sources).

Called by render-and-run.sh when NEO4J_AUTH_MODE=oidc -- not meant to be
run standalone against untrusted input (see render-and-run.sh's validation
of every value substituted into a Cypher template before this ever runs).

Requires: pip install neo4j (no other third-party dependency -- the Entra
token request uses only the standard library, deliberately, so this script
has one dependency to install on a pipeline agent, not two).

Required env vars:
  NEO4J_BOLT_URI            e.g. neo4j+s://neo4j-aks.internal:7687
  ENTRA_TENANT_ID           Entra tenant (Directory) ID
  PIPELINE_CLIENT_ID        Application (client) ID of the pipeline's OWN
                             app registration/service principal -- NOT the
                             Neo4j SSO app registration
                             (terraform's neo4j_oidc_client_id).
  PIPELINE_CLIENT_SECRET    That service principal's client secret.
  NEO4J_OIDC_AUDIENCE_SCOPE The scope to request, e.g.
                             api://<neo4j-sso-client-id>/.default -- must
                             resolve to an access token whose `aud` claim
                             matches dbms.security.oidc.azure.audience
                             (terraform/neo4j.tf), i.e. the Neo4j SSO app
                             registration's Application ID, not this
                             script's own PIPELINE_CLIENT_ID.

Usage:
  run_cypher_oidc.py <rendered-cypher-file>
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def get_access_token() -> str:
    tenant_id = _require_env("ENTRA_TENANT_ID")
    client_id = _require_env("PIPELINE_CLIENT_ID")
    client_secret = _require_env("PIPELINE_CLIENT_SECRET")
    scope = _require_env("NEO4J_OIDC_AUDIENCE_SCOPE")

    token_url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    body = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": scope,
            "grant_type": "client_credentials",
        }
    ).encode()

    request = urllib.request.Request(token_url, data=body, method="POST")
    try:
        with urllib.request.urlopen(request) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise SystemExit(
            f"error: Entra token request failed ({exc.code}): {detail}"
        ) from exc

    token = payload.get("access_token")
    if not token:
        raise SystemExit(f"error: no access_token in Entra response: {payload}")
    return token


def _require_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"error: {name} must be set")
    return value


def split_statements(cypher_text: str) -> list[str]:
    """Splits a rendered .cypher.tpl file into individual statements.

    cypher-shell's -f flag runs a whole file, splitting on ";" itself; the
    driver's session.run() executes one statement at a time, so this does
    the same split by hand. Safe here specifically because every value
    substituted into these templates is pre-validated by render-and-run.sh
    against a strict identifier/GUID regex before reaching this file --
    none of it can contain a literal ";" to confuse this split.
    """
    statements = []
    current: list[str] = []
    for line in cypher_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        current.append(line)
        if stripped.endswith(";"):
            statements.append("\n".join(current))
            current = []
    if current and "".join(current).strip():
        statements.append("\n".join(current))
    return [s for s in statements if s.strip()]


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: run_cypher_oidc.py <rendered-cypher-file>", file=sys.stderr)
        raise SystemExit(1)

    from neo4j import GraphDatabase, bearer_auth  # imported late so --help/usage errors don't require it installed

    uri = _require_env("NEO4J_BOLT_URI")
    cypher_text = open(sys.argv[1], encoding="utf-8").read()
    statements = split_statements(cypher_text)

    token = get_access_token()

    with GraphDatabase.driver(uri, auth=bearer_auth(token)) as driver:
        with driver.session() as session:
            for statement in statements:
                print(f"---- running ----\n{statement}\n-----------------")
                session.run(statement).consume()


if __name__ == "__main__":
    main()
