#!/usr/bin/env bash
# contabo-api.sh — Contabo Cloud API helpers (auth + DNS records).
#
# Two things bite everyone on first contact with this API:
#
#   * EVERY request needs its own `x-request-id` header — the auth call
#     included. Without it the API returns 400 no matter how correct the
#     credentials are, which reads like an auth failure and isn't one.
#   * The API password is a DEDICATED password generated in the Contabo
#     panel (Security & Access > Password > Send Link), NOT the normal
#     account login password. Using the login password doesn't return an
#     authentication error — it returns a null token, so the failure looks
#     like a bug in your script rather than a wrong credential.

CONTABO_AUTH_URL="https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token"
CONTABO_API_BASE="https://api.contabo.com/v1"

contabo_request_id() {
  if have_cmd uuidgen; then
    uuidgen
  else
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

# Extracts a field from a JSON document on stdin without ever throwing on
# malformed input — an API error page or an HTML redirect would otherwise
# crash the caller with a Python traceback instead of a useful message.
_json_get() {
  local path="$1"
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key in '${path}'.split('.'):
    if isinstance(d, dict):
        d = d.get(key)
    else:
        d = None
    if d is None:
        sys.exit(0)
print(d)
" 2>/dev/null
}

# Surfaces an API error message if the response contains one.
_json_error() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    for k in ('message', 'error_description', 'error', 'detail'):
        if d.get(k):
            print(d[k]); break
" 2>/dev/null
}

# Fetches a fresh access token. Tokens expire in 300 seconds, so this is
# called per domain rather than cached across a long batch run.
#
# --data-urlencode, never plain -d: a password containing a literal '%'
# is mangled by -d as a malformed percent-escape, producing an auth
# failure that looks like a wrong password.
contabo_token() {
  local resp token
  resp=$(curl -sS -X POST "$CONTABO_AUTH_URL" \
    -H "x-request-id: $(contabo_request_id)" \
    --data-urlencode "client_id=${CONTABO_CLIENT_ID:-}" \
    --data-urlencode "client_secret=${CONTABO_CLIENT_SECRET:-}" \
    --data-urlencode "username=${CONTABO_API_USER:-}" \
    --data-urlencode "password=${CONTABO_API_PASSWORD:-}" \
    --data-urlencode "grant_type=password" 2>/dev/null)

  token=$(printf '%s' "$resp" | _json_get access_token)
  if [[ -z "$token" ]]; then
    local msg
    msg=$(printf '%s' "$resp" | _json_error)
    [[ -n "$msg" ]] && warn "Contabo auth error: ${msg}" >&2
    return 1
  fi
  printf '%s' "$token"
}

# contabo_dns_list <domain> <token>
# Response shape (verified against the live API):
#   {"data":[{"recordId":...,"name":...,"type":...,"data":...,"ttl":...,"prio":...}]}
# Note the field is `recordId`, not `id`.
contabo_dns_list() {
  local domain="$1" token="$2"
  curl -sS -H "Authorization: Bearer $token" -H "x-request-id: $(contabo_request_id)" \
    "${CONTABO_API_BASE}/dns/zones/${domain}/records" 2>/dev/null
}

contabo_dns_create() {
  local domain="$1" token="$2" name="$3" type="$4" value="$5" ttl="${6:-86400}" prio="${7:-0}"
  local body
  body=$(python3 -c "
import json, sys
print(json.dumps({'name': sys.argv[1], 'type': sys.argv[2], 'data': sys.argv[3],
                  'ttl': int(sys.argv[4]), 'prio': int(sys.argv[5])}))
" "$name" "$type" "$value" "$ttl" "$prio")
  curl -sS -X POST -H "Authorization: Bearer $token" -H "x-request-id: $(contabo_request_id)" \
    -H "Content-Type: application/json" \
    "${CONTABO_API_BASE}/dns/zones/${domain}/records" -d "$body" 2>/dev/null
}

# A full record body is required on update, including prio — even for
# record types where priority is meaningless.
contabo_dns_update() {
  local domain="$1" token="$2" record_id="$3" name="$4" type="$5" value="$6" ttl="${7:-86400}" prio="${8:-0}"
  local body
  body=$(python3 -c "
import json, sys
print(json.dumps({'name': sys.argv[1], 'type': sys.argv[2], 'data': sys.argv[3],
                  'ttl': int(sys.argv[4]), 'prio': int(sys.argv[5])}))
" "$name" "$type" "$value" "$ttl" "$prio")
  curl -sS -X PATCH -H "Authorization: Bearer $token" -H "x-request-id: $(contabo_request_id)" \
    -H "Content-Type: application/json" \
    "${CONTABO_API_BASE}/dns/zones/${domain}/records/${record_id}" -d "$body" 2>/dev/null
}

contabo_dns_delete() {
  local domain="$1" token="$2" record_id="$3"
  curl -sS -X DELETE -H "Authorization: Bearer $token" -H "x-request-id: $(contabo_request_id)" \
    "${CONTABO_API_BASE}/dns/zones/${domain}/records/${record_id}" 2>/dev/null
}

# Returns the recordId of a record matching name+type exactly, or nothing.
contabo_dns_find_id() {
  local domain="$1" token="$2" name="$3" type="$4"
  contabo_dns_list "$domain" "$token" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
want_name, want_type = sys.argv[1].lower(), sys.argv[2].upper()
for r in (d.get('data') or []):
    if str(r.get('name','')).lower() == want_name and str(r.get('type','')).upper() == want_type:
        print(r.get('recordId'))
        break
" "$name" "$type" 2>/dev/null
}

# Returns the current value (the `data` field) of a matching record.
contabo_dns_get_value() {
  local domain="$1" token="$2" name="$3" type="$4"
  contabo_dns_list "$domain" "$token" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
want_name, want_type = sys.argv[1].lower(), sys.argv[2].upper()
for r in (d.get('data') or []):
    if str(r.get('name','')).lower() == want_name and str(r.get('type','')).upper() == want_type:
        print(r.get('data',''))
        break
" "$name" "$type" 2>/dev/null
}

# Updates a record if one with the same name AND type exists, creates it
# otherwise. Records of other types at the same name are never touched —
# so updating a domain's A record cannot disturb its MX or a TXT record.
contabo_dns_upsert() {
  local domain="$1" token="$2" name="$3" type="$4" value="$5" ttl="${6:-86400}" prio="${7:-0}"
  local id
  id=$(contabo_dns_find_id "$domain" "$token" "$name" "$type")
  if [[ -n "$id" ]]; then
    contabo_dns_update "$domain" "$token" "$id" "$name" "$type" "$value" "$ttl" "$prio"
  else
    contabo_dns_create "$domain" "$token" "$name" "$type" "$value" "$ttl" "$prio"
  fi
}

# Rewrites SPF while preserving every existing `include:` mechanism.
#
# This function exists because blindly replacing an SPF record breaks
# outbound mail for any domain that uses a third-party mail provider
# (Zoho, Microsoft 365, Google Workspace): their include: mechanism is
# what authorizes their servers to send as that domain. The failure is
# invisible at cutover time and shows up later as mail landing in spam.
contabo_dns_upsert_spf() {
  local domain="$1" token="$2" new_ip="$3"
  local existing includes spf

  existing=$(contabo_dns_list "$domain" "$token" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in (d.get('data') or []):
    if str(r.get('type','')).upper() == 'TXT' and str(r.get('data','')).startswith('v=spf1'):
        print(r.get('data'))
        break
" 2>/dev/null)

  includes=$(printf '%s' "$existing" | grep -oE 'include:[^ ]+' | tr '\n' ' ')
  spf=$(printf 'v=spf1 +mx +a %s+ip4:%s ~all' "$includes" "$new_ip" | tr -s ' ')

  if [[ -n "$includes" ]]; then
    log "    Preserving SPF include mechanisms: ${includes}" >&2
  fi
  contabo_dns_upsert "$domain" "$token" "$domain" "TXT" "$spf"
}
