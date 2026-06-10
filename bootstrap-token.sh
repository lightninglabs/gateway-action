#!/usr/bin/env bash
#
# bootstrap-token.sh — mint a short-lived, least-privilege GitHub App
# installation token that can read ONLY the private gateway runtime repo.
#
# This is the one piece of logic that must live in the PUBLIC action repo,
# because it runs BEFORE the private runtime is checked out. It is a trimmed
# copy of gateway's scripts/authenticate.sh — JWT minting only, plus an
# installation-id discovery step and a repo/permission-scoped token request.
# It contains NO review logic; keep it that way.
#
# What it does:
#   1. Build an RS256 App JWT from the App credentials.
#   2. Discover the installation that owns the runtime repo
#      (GET /repos/<owner>/<repo>/installation) — so the org installation id
#      is never hardcoded here.
#   3. Mint an installation token scoped to { repositories: [<repo>],
#      permissions: { contents: read } } — the minimum needed to checkout it.
#
# Required env:
#   BOOTSTRAP_APP_ID         numeric GitHub App ID
#   BOOTSTRAP_PRIVATE_KEY    full PEM contents of the App's private key
#
# Optional env (defaults target the gateway runtime):
#   RUNTIME_OWNER            default: lightninglabs
#   RUNTIME_REPO             default: gateway
#
# Output:
#   stdout (one line): the installation token, raw (no surrounding JSON).
#   stderr           : structured JSON log lines (one object per line).
#
# Exit codes:
#   0  success
#   2  system error (missing/invalid input, signing failure, network failure,
#                    or non-2xx GitHub API response)

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly GITHUB_API="${GITHUB_API_URL:-https://api.github.com}"
readonly RUNTIME_OWNER="${RUNTIME_OWNER:-lightninglabs}"
readonly RUNTIME_REPO="${RUNTIME_REPO:-gateway}"

# ---------------------------------------------------------------------------
# Logging helpers (structured JSON to stderr; never logs the token)
# ---------------------------------------------------------------------------

log() {
  local level="$1" event="$2" outcome="$3"
  local extra="${4:-}"
  if [[ -z "$extra" ]]; then
    extra='{}'
  fi
  jq -cn \
    --arg level   "$level" \
    --arg script  "$SCRIPT_NAME" \
    --arg event   "$event" \
    --arg outcome "$outcome" \
    --argjson extra "$extra" \
    '{level:$level, script:$script, event:$event, outcome:$outcome} + $extra' >&2
}

die() {
  local msg="$1" event="$2"
  log error "$event" failure "$(jq -cn --arg m "$msg" '{message:$m}')"
  exit 2
}

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    die "required env var $var is unset or empty" validate_env
  fi
}

# base64url encode stdin (RFC 4648 §5): standard base64, strip '=' padding and
# newlines, translate '+/' to '-_'.
b64url() {
  base64 | tr -d '=\n' | tr '/+' '_-'
}

# curl wrapper: GET/POST with one retry on 5xx / network failure. Writes the
# response body to $1 and echoes the HTTP status code.
http_request() {
  local method="$1" url="$2" out="$3" body="${4:-}"
  local attempt=1 max_attempts=2 code=""
  while (( attempt <= max_attempts )); do
    local -a args=(
      -sS -o "$out" -w '%{http_code}'
      -X "$method"
      -H "Authorization: Bearer ${JWT}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28"
    )
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
    code=$(curl "${args[@]}" "$url" 2>"$ERR_FILE") || true
    [[ -z "$code" ]] && code="000"
    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
      break
    fi
    if (( attempt < max_attempts )) && \
       { [[ "$code" =~ ^5[0-9][0-9]$ ]] || [[ "$code" == "000" ]]; }; then
      log warn "$method" retry "$(jq -cn --arg s "$code" '{http_status:$s, sleep_seconds:2}')"
      sleep 2
      attempt=$((attempt + 1))
      continue
    fi
    break
  done
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# 1. Validate inputs
# ---------------------------------------------------------------------------

require_env BOOTSTRAP_APP_ID
require_env BOOTSTRAP_PRIVATE_KEY

if ! [[ "$BOOTSTRAP_APP_ID" =~ ^[0-9]+$ ]]; then
  die "BOOTSTRAP_APP_ID must be numeric" validate_env
fi

# ---------------------------------------------------------------------------
# 2. Materialize the private key safely
# ---------------------------------------------------------------------------

KEY_FILE="$(mktemp -t gateway-action-key.XXXXXX)"
RESP_FILE="$(mktemp -t gateway-action-resp.XXXXXX)"
ERR_FILE="$(mktemp -t gateway-action-err.XXXXXX)"
chmod 600 "$KEY_FILE"
trap 'rm -f "$KEY_FILE" "$RESP_FILE" "$ERR_FILE"' EXIT

# printf '%s' preserves the PEM as-is (echo would mangle backslashes on some
# shells, and we must keep the trailing newline valid PEM blocks have).
printf '%s' "$BOOTSTRAP_PRIVATE_KEY" > "$KEY_FILE"

# ---------------------------------------------------------------------------
# 3. Build the JWT (RS256)
# ---------------------------------------------------------------------------

NOW=$(date +%s)
IAT=$((NOW - 60))    # backdate 60s to absorb clock skew vs GitHub
EXP=$((NOW + 540))   # 9 minutes; GitHub's max is 10

HEADER_B64=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)

# Build payload via jq so iss is a proper JSON integer (no quoting). -j
# suppresses jq's trailing newline, which would otherwise be base64url-encoded
# into the payload and yield a nonstandard JWT body.
PAYLOAD_B64=$(
  jq -cnj \
    --argjson iat "$IAT" \
    --argjson exp "$EXP" \
    --argjson iss "$BOOTSTRAP_APP_ID" \
    '{iat:$iat, exp:$exp, iss:$iss}' | b64url
)

SIGNING_INPUT="${HEADER_B64}.${PAYLOAD_B64}"

SIG_B64=$(
  printf '%s' "$SIGNING_INPUT" \
    | openssl dgst -sha256 -sign "$KEY_FILE" -binary 2>"$ERR_FILE" \
    | b64url
) || {
  err_msg="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  die "openssl signing failed: ${err_msg:-unknown error}" sign_jwt
}

if [[ -z "$SIG_B64" ]]; then
  die "openssl produced empty signature (malformed private key?)" sign_jwt
fi

JWT="${SIGNING_INPUT}.${SIG_B64}"
readonly JWT

log info sign_jwt success "$(jq -cn --arg app "$BOOTSTRAP_APP_ID" '{app_id:$app}')"

# ---------------------------------------------------------------------------
# 4. Discover the installation that owns the runtime repo
# ---------------------------------------------------------------------------

INST_URL="${GITHUB_API}/repos/${RUNTIME_OWNER}/${RUNTIME_REPO}/installation"
code=$(http_request GET "$INST_URL" "$RESP_FILE")
if ! [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
  body_excerpt="$(head -c 500 "$RESP_FILE" 2>/dev/null | tr '\n' ' ' || true)"
  die "could not resolve installation for ${RUNTIME_OWNER}/${RUNTIME_REPO} (HTTP ${code}): ${body_excerpt}. Is the App installed on that repo with contents:read?" discover_installation
fi

INSTALLATION_ID=$(jq -er '.id' "$RESP_FILE" 2>"$ERR_FILE") \
  || die "installation response missing .id" discover_installation

log info discover_installation success \
  "$(jq -cn --arg i "$INSTALLATION_ID" --arg r "${RUNTIME_OWNER}/${RUNTIME_REPO}" '{installation_id:$i, repo:$r}')"

# ---------------------------------------------------------------------------
# 5. Mint a least-privilege installation token (repo-scoped, contents:read)
# ---------------------------------------------------------------------------

TOKEN_URL="${GITHUB_API}/app/installations/${INSTALLATION_ID}/access_tokens"
TOKEN_BODY=$(
  jq -cn --arg repo "$RUNTIME_REPO" \
    '{repositories: [$repo], permissions: {contents: "read"}}'
)

code=$(http_request POST "$TOKEN_URL" "$RESP_FILE" "$TOKEN_BODY")
if ! [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
  body_excerpt="$(head -c 500 "$RESP_FILE" 2>/dev/null | tr '\n' ' ' || true)"
  die "GitHub API HTTP ${code}: ${body_excerpt}" mint_token
fi

TOKEN=$(jq -er '.token' "$RESP_FILE" 2>"$ERR_FILE") \
  || die "token response missing .token" mint_token

# Raw token on stdout, exactly once. Never logged.
printf '%s' "$TOKEN"

log info mint_token success "$(jq -cn '{scope: "contents:read", repositories: 1}')"
