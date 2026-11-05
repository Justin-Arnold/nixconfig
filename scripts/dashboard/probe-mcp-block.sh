#!/usr/bin/env bash
# Checks that Homarr's MCP endpoint, its OAuth routes and the page that
# approves MCP clients are unreachable, by sending unauthenticated GET and POST
# requests. Read-only.
#
#   scripts/dashboard/probe-mcp-block.sh [base-url ...]
#
# Only a 404 counts as blocked: that's nginx/homarr-guard.conf answering. A
# 403 means the guard didn't match and an allow-list stopped the request
# instead, which counts as a failure. A redirect usually means Pangolin's SSO
# answered first, which proves nothing about the host, so run this from the
# LAN (the default URL then resolves to the VM). Pangolin's requests end at the
# same server blocks, so the LAN run covers them too.
#
# Extra curl arguments can go in PROBE_CURL_ARGS (for example -k).
set -u

bases=("$@")
[[ ${#bases[@]} -gt 0 ]] || bases=(https://dashboard.servicestack.xyz)
read -r -a extra <<<"${PROBE_CURL_ARGS:-}"

paths=(
  /api/mcp /api/mcp/ /api/mcp/mcp /api//mcp /API/MCP /%61pi/mcp /api/%6Dcp
  /api/mcp/oauth/authorize /api/mcp/oauth/token /api/mcp/oauth/register
  /.well-known/oauth-authorization-server /.well-known/oauth-protected-resource
  /.well-known/oauth-protected-resource/api/mcp /.well-known/openid-configuration
  /en/auth/mcp /auth/mcp /de/auth/mcp/error /EN/AUTH/MCP
)

bad=0
for base in "${bases[@]}"; do
  echo "== $base"
  for path in "${paths[@]}"; do
    for method in GET POST; do
      code="$(curl -s -o /dev/null -w '%{http_code}' --path-as-is --max-time 10 -X "$method" \
        ${extra[@]+"${extra[@]}"} "$base$path")"
      case "$code" in
        404) verdict="blocked" ;;
        30[1278]) verdict="redirect (SSO answered first; not proof)" ;;
        000) verdict="no answer" ;;
        403) verdict="FAIL: guard didn't match"; bad=1 ;;
        *) verdict="FAIL: reached Homarr"; bad=1 ;;
      esac
      printf '  %-4s %-48s %s  %s\n' "$method" "$path" "$code" "$verdict"
    done
  done
done
exit "$bad"
