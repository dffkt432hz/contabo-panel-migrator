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

# _contabo_call <METHOD> <url> <token> [json-body]
#
# Prints the response body and returns 0 ONLY for an HTTP 2xx. Anything else
# (4xx/5xx, or no response at all) prints the API's own error message and
# returns 1. Before this existed every DNS call discarded its result, so a
# rejected update was reported to the operator as "DNS updated".
_contabo_call() {
  local method="$1" url="$2" token="$3" body="${4:-}"
  local nl=$'\n' resp code payload msg
  local -a args
  args=(-sS -X "$method" -H "Authorization: Bearer $token" -H "x-request-id: $(contabo_request_id)" -w "${nl}%{http_code}")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  resp=$(curl "${args[@]}" "$url" 2>/dev/null)
  code="${resp##*"$nl"}"
  payload="${resp%"$nl"*}"
  printf '%s' "$payload"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi
  msg=$(printf '%s' "$payload" | _json_error)
  warn "Contabo API ${method} failed (HTTP ${code:-no response})${msg:+: ${msg}}" >&2
  return 1
}

# contabo_dns_list <domain> <token>
# Response shape (verified against the live API):
#   {"data":[{"recordId":...,"name":...,"type":...,"data":...,"ttl":...,"prio":...}]}
# Note the field is `recordId`, not `id`. Returns non-zero when the zone
# cannot be read (for instance because the domain's DNS is not hosted at
# Contabo), so callers never mistake "could not read" for "no records".
contabo_dns_list() {
  local domain="$1" token="$2"
  _contabo_call GET "${CONTABO_API_BASE}/dns/zones/${domain}/records" "$token"
}

_contabo_record_body() {
  python3 -c "
import json, sys
print(json.dumps({'name': sys.argv[1], 'type': sys.argv[2], 'data': sys.argv[3],
                  'ttl': int(sys.argv[4]), 'prio': int(sys.argv[5])}))
" "$1" "$2" "$3" "$4" "$5"
}

contabo_dns_create() {
  local domain="$1" token="$2" name="$3" type="$4" value="$5" ttl="${6:-86400}" prio="${7:-0}"
  _contabo_call POST "${CONTABO_API_BASE}/dns/zones/${domain}/records" "$token" \
    "$(_contabo_record_body "$name" "$type" "$value" "$ttl" "$prio")"
}

# A full record body is required on update, including prio — even for
# record types where priority is meaningless.
contabo_dns_update() {
  local domain="$1" token="$2" record_id="$3" name="$4" type="$5" value="$6" ttl="${7:-86400}" prio="${8:-0}"
  _contabo_call PATCH "${CONTABO_API_BASE}/dns/zones/${domain}/records/${record_id}" "$token" \
    "$(_contabo_record_body "$name" "$type" "$value" "$ttl" "$prio")"
}

contabo_dns_delete() {
  local domain="$1" token="$2" record_id="$3"
  _contabo_call DELETE "${CONTABO_API_BASE}/dns/zones/${domain}/records/${record_id}" "$token"
}

# contabo_dns_find_record <domain> <token> <name> <type>
# Prints "recordId<TAB>ttl<TAB>data" for the first record matching name and
# type exactly (nothing if there is none). Returns 2 if the zone could not
# be read, so "not found" and "could not look" stay distinguishable.
contabo_dns_find_record() {
  local domain="$1" token="$2" name="$3" type="$4" resp
  resp=$(contabo_dns_list "$domain" "$token") || return 2
  printf '%s' "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
want_name, want_type = sys.argv[1].lower(), sys.argv[2].upper()
for r in (d.get('data') or []):
    if str(r.get('name','')).lower() == want_name and str(r.get('type','')).upper() == want_type:
        print('%s\t%s\t%s' % (r.get('recordId'), r.get('ttl', ''), r.get('data', '')))
        break
" "$name" "$type" 2>/dev/null
}

# Returns the recordId of a record matching name+type exactly, or nothing.
contabo_dns_find_id() {
  local rec
  rec=$(contabo_dns_find_record "$@") || return 2
  printf '%s' "$rec" | cut -f1
}

# Returns the current value (the `data` field) of a matching record.
contabo_dns_get_value() {
  local rec
  rec=$(contabo_dns_find_record "$@") || return 2
  printf '%s' "$rec" | cut -f3-
}

# Updates a record if one with the same name AND type exists, creates it
# otherwise. Records of other types at the same name are never touched —
# so updating a domain's A record cannot disturb its MX or a TXT record.
#
# On update the record's EXISTING ttl is kept. Forcing a fixed 86400 here
# would turn a short TTL the operator chose (to allow a quick rollback) into
# a full day, exactly when it matters most.
contabo_dns_upsert() {
  local domain="$1" token="$2" name="$3" type="$4" value="$5" ttl="${6:-}" prio="${7:-0}"
  local rec rc id old_ttl
  rec=$(contabo_dns_find_record "$domain" "$token" "$name" "$type"); rc=$?
  [[ $rc -eq 2 ]] && return 1
  id=$(printf '%s' "$rec" | cut -f1)
  old_ttl=$(printf '%s' "$rec" | cut -f2)
  if [[ -n "$id" ]]; then
    [[ -z "$ttl" ]] && ttl="${old_ttl:-86400}"
    contabo_dns_update "$domain" "$token" "$id" "$name" "$type" "$value" "$ttl" "$prio"
  else
    contabo_dns_create "$domain" "$token" "$name" "$type" "$value" "${ttl:-86400}" "$prio"
  fi
}

# spf_rewrite <existing SPF record or empty> <new server IPv4>
#
# Adds the new server's ip4: to a domain's SPF while keeping everything the
# domain already had: every include:, a, mx, other ip4:/ip6:, exists:, and the
# domain's own -all / ~all / ?all policy. A domain that uses a third-party
# mail provider (Zoho, Microsoft 365, Google Workspace) depends on its
# include: to authorize that provider, and overwriting it breaks outbound
# mail invisibly, showing up later as mail landing in spam.
#
# A record that delegates with redirect= is returned unchanged: adding an
# "all" after a redirect would make receivers ignore the redirect entirely.
# With no existing record, a conservative default is produced.
spf_rewrite() {
  local existing="${1:-}" new_ip="$2" tok mechs="" allq="~all" have_ip=0
  if [[ -z "$existing" ]]; then
    printf 'v=spf1 +mx +a +ip4:%s ~all' "$new_ip"
    return 0
  fi
  for tok in $existing; do
    if [[ "$tok" == redirect=* ]]; then
      printf '%s' "$existing"
      return 0
    fi
  done
  for tok in $existing; do
    case "$tok" in
      v=spf1) ;;
      all|+all|-all|~all|\?all) allq="$tok" ;;
      ip4:"$new_ip"|+ip4:"$new_ip") have_ip=1; mechs+=" $tok" ;;
      *) mechs+=" $tok" ;;
    esac
  done
  [[ $have_ip -eq 1 ]] || mechs+=" +ip4:${new_ip}"
  printf 'v=spf1%s %s' "$mechs" "$allq"
}

# Adds the new server to the domain's SPF record, in place.
#
# The record to change is FOUND BY ITS CONTENT (a TXT starting "v=spf1" at the
# apex) and updated by its own id. An apex usually carries several TXT
# records (site verification, DKIM helpers, the SPF itself); matching on
# "the first TXT at the apex" would overwrite whichever happens to be listed
# first — possibly a verification record — and leave the real SPF untouched.
contabo_dns_upsert_spf() {
  local domain="$1" token="$2" new_ip="$3"
  local resp rec id name ttl existing spf
  resp=$(contabo_dns_list "$domain" "$token") || return 1

  rec=$(printf '%s' "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
apex = sys.argv[1].lower()
for r in (d.get('data') or []):
    n = str(r.get('name', '')).lower()
    if str(r.get('type', '')).upper() == 'TXT' and n in (apex, '@', '') \
       and str(r.get('data', '')).startswith('v=spf1'):
        print('%s\t%s\t%s\t%s' % (r.get('recordId'), r.get('name', ''), r.get('ttl', ''), r.get('data', '')))
        break
" "$domain" 2>/dev/null)

  id=$(printf '%s' "$rec" | cut -f1)
  name=$(printf '%s' "$rec" | cut -f2)
  ttl=$(printf '%s' "$rec" | cut -f3)
  existing=$(printf '%s' "$rec" | cut -f4-)
  spf=$(spf_rewrite "$existing" "$new_ip")

  if [[ -n "$existing" && "$existing" == *redirect=* ]]; then
    warn "    SPF uses redirect= — left unchanged. If the new server sends mail, add ip4:${new_ip} at the redirect target." >&2
    return 0
  fi
  if [[ -n "$existing" && "$spf" == "$existing" ]]; then
    log "    SPF already authorizes ${new_ip}." >&2
    return 0
  fi
  if [[ -n "$existing" ]]; then
    log "    Keeping the existing SPF mechanisms and adding ip4:${new_ip}" >&2
    contabo_dns_update "$domain" "$token" "$id" "${name:-$domain}" "TXT" "$spf" "${ttl:-86400}" 0
  else
    contabo_dns_create "$domain" "$token" "$domain" "TXT" "$spf"
  fi
}
