#!/usr/bin/env bash
# run-tests.sh — offline test suite. No real servers required.
#
# Remote execution is exercised through tests/mock-ssh/ssh, a stand-in that
# strips SSH's options and runs the command locally, so the real wrappers
# (including their stdin handling, which is where the nastiest bug in this
# toolkit lived) are tested for real rather than mocked away.
#
# Usage: tests/run-tests.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export PATH="$REPO_ROOT/tests/mock-ssh:$PATH"

export SOURCE_HOST=source.invalid TARGET_HOST=target.invalid
export SOURCE_SSH_USER=root TARGET_SSH_USER=root
TMP=$(mktemp -d)
export AUDIT_DIR="$TMP/audit"
mkdir -p "$AUDIT_DIR"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/contabo-api.sh
source "$REPO_ROOT/lib/contabo-api.sh"
# shellcheck source=../lib/audit-source.sh
source "$REPO_ROOT/lib/audit-source.sh"
# shellcheck source=../lib/audit-target.sh
source "$REPO_ROOT/lib/audit-target.sh"
# shellcheck source=../lib/migrate-account.sh
source "$REPO_ROOT/lib/migrate-account.sh"
# shellcheck source=../lib/dns-cutover.sh
source "$REPO_ROOT/lib/dns-cutover.sh"
# shellcheck source=../lib/sanity-check.sh
source "$REPO_ROOT/lib/sanity-check.sh"

PASS=0; FAIL=0
check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  \033[0;32mPASS\033[0m %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  \033[0;31mFAIL\033[0m %s\n        got:  |%s|\n        want: |%s|\n' "$name" "$got" "$want"
    FAIL=$((FAIL+1))
  fi
}
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
group "Virtualmin --multiline parsing (leading whitespace tolerance)"
check "indented field" \
  "$(printf '    Name: Default Plan\n    Server block quota: Unlimited\n' | vm_field 'Server block quota')" \
  "Unlimited"
check "unindented field" "$(printf 'Name: Foo\n' | vm_field Name)" "Foo"
check "absent field is empty" "$(printf '    Name: Foo\n' | vm_field Missing)" ""

# ---------------------------------------------------------------------------
group "Config edits tolerate any spacing style"
printf 'memory_limit = 128M\nupload_max_filesize=2M\n' > "$TMP/php.ini"
c_set_kv "$TMP/php.ini" memory_limit 1024M
c_set_kv "$TMP/php.ini" upload_max_filesize 256M
check "spaced   key=value" "$(grep -c '^memory_limit=1024M' "$TMP/php.ini")" "1"
check "unspaced key=value" "$(grep -c '^upload_max_filesize=256M' "$TMP/php.ini")" "1"

# ---------------------------------------------------------------------------
group "SSH stdin handling (the bug that made batch loops process one item)"
check "c_ssh runs the remote command" "$(c_ssh target 'echo hello')" "hello"
check "c_ssh does NOT consume the caller's stdin" \
  "$(printf 'a\nb\nc\n' | { read -r first; c_ssh target 'cat' >/dev/null; echo "first=$first"; })" \
  "first=a"
check "c_ssh_pipe DOES pass stdin through (database imports depend on it)" \
  "$(echo 'SQLDATA' | c_ssh_pipe target 'cat')" \
  "SQLDATA"

n=0
while IFS=$'\t' read -r dom acct; do
  [[ -z "$dom" ]] && continue
  c_ssh target "true"
  [[ -n "$acct" ]] && n=$((n+1))
done <<< $'a.com\tu1\nb.com\tu2\nc.com\tu3'
check "a loop calling c_ssh processes every account, not just the first" "$n" "3"

# ---------------------------------------------------------------------------
group "remote_script survives hostile quoting"
check "no arguments" "$(remote_script target <<'EOF'
echo plain
EOF
)" "plain"

NASTY='p$a"s`s'"'"'w*rd'
check "password with \$ \" \` ' and * passes through verbatim" \
  "$(remote_script target "$NASTY" <<'EOF'
printf '%s' "$1"
EOF
)" "$NASTY"

# ---------------------------------------------------------------------------
group "Application database credential discovery"
mkdir -p "$TMP/wp" "$TMP/lara/public" "$TMP/joom" "$TMP/none"

cat > "$TMP/wp/wp-config.php" <<'EOF'
<?php
define( 'DB_NAME', 'site_wp' );
define('DB_USER', 'site_usr');
define( 'DB_PASSWORD', 'p$a"ss`w*rd' );
EOF
check "WordPress (single-quoted, password contains \" \` *)" \
  "$(discover_app_db_credentials x "$TMP/wp")" \
  "$(printf 'site_wp\tsite_usr\tp$a"ss`w*rd')"

cat > "$TMP/wp/wp-config.php" <<'EOF'
<?php
define( "DB_NAME", "dq_db" );
define( "DB_USER", "dq_user" );
define( "DB_PASSWORD", "it's-a-pass" );
EOF
check "WordPress (double-quoted, password contains an apostrophe)" \
  "$(discover_app_db_credentials x "$TMP/wp")" \
  "dq_db"$'\t'"dq_user"$'\t'"it's-a-pass"

cat > "$TMP/lara/.env" <<'EOF'
APP_ENV=production
DB_DATABASE=lara_db
DB_USERNAME="lara_user"
DB_PASSWORD='l@r4$pass'
EOF
check "Laravel .env found one level above public/" \
  "$(discover_app_db_credentials x "$TMP/lara/public")" \
  "$(printf 'lara_db\tlara_user\tl@r4$pass')"

cat > "$TMP/joom/configuration.php" <<'EOF'
<?php class JConfig {
 public $db = 'joom_db';
 public $user = 'joom_user';
 public $password = 'jo"om`P@ss';
}
EOF
check "Joomla configuration.php" \
  "$(discover_app_db_credentials x "$TMP/joom")" \
  "$(printf 'joom_db\tjoom_user\tjo"om`P@ss')"

check "no recognizable config yields empty fields" \
  "$(discover_app_db_credentials x "$TMP/none")" "$(printf '\t\t')"

# ---------------------------------------------------------------------------
group "Sanity-check counters survive the reporting loop"
SANITY_ISSUES=0; SANITY_CHECKS=0; SANITY_FINDINGS=""
while read -r d; do
  [[ -z "$d" ]] && continue
  _report WARN "issue on $d" "fix-$d" 2>/dev/null
  _report PASS "ok on $d" >/dev/null
done <<< $'a.com\nb.com\nc.com'
check "issues counted across the loop" "$SANITY_ISSUES" "3"
check "checks counted across the loop" "$SANITY_CHECKS" "6"
check "findings recorded for the report" "$(grep -c 'issue on' <<<"$SANITY_FINDINGS")" "3"

# ---------------------------------------------------------------------------
group "Contabo API parsing never throws on unexpected responses"
check "token extracted"          "$(echo '{"access_token":"abc123"}' | _json_get access_token)" "abc123"
check "null token -> empty"      "$(echo '{"access_token":null}'     | _json_get access_token)" ""
check "HTML error page -> empty" "$(echo '<html>502</html>'          | _json_get access_token)" ""
check "empty body -> empty"      "$(printf ''                        | _json_get access_token)" ""
check "oauth error surfaced"     "$(echo '{"error_description":"Invalid user credentials"}' | _json_error)" "Invalid user credentials"
check "api error surfaced"       "$(echo '{"message":"invalid client"}' | _json_error)" "invalid client"

# ---------------------------------------------------------------------------
group "Mailbox discovery filters out non-addresses"
check "bare catch-all usernames are not treated as mailboxes" \
  "$(printf '  email: real@example.com\n  email: catchalluser\n  email: other@example.com\n' \
     | sed -n 's/^[[:space:]]*email:[[:space:]]*//p' | grep '@' | tr '\n' ',')" \
  "real@example.com,other@example.com,"

# ---------------------------------------------------------------------------
group "Row verification uses real counts, not estimates"
if grep -q 'COUNT(\*)' "$REPO_ROOT/lib/common.sh"; then
  check "db_total_rows uses COUNT(*)" "yes" "yes"
else
  check "db_total_rows uses COUNT(*)" "no" "yes"
fi
if grep -q 'table_rows' "$REPO_ROOT/lib/common.sh" | grep -qv '^#'; then
  check "table_rows estimate not used in code" "used" "not-used"
else
  check "table_rows estimate not used in code" "not-used" "not-used"
fi


# ---------------------------------------------------------------------------
group "Wiring: every library the wizard sources exists and loads"
WIZ_LIBS=$(sed -n 's/^for _lib in \(.*\); do$/\1/p' "$REPO_ROOT/bin/migrate-wizard.sh")
MISSING_LIBS=""
for _l in $WIZ_LIBS; do [[ -f "$REPO_ROOT/lib/${_l}.sh" ]] || MISSING_LIBS+="${_l} "; done
check "no library named by the wizard is missing" "${MISSING_LIBS:-none}" "none"
check "wizard names the audit libraries" \
  "$([[ " $WIZ_LIBS " == *" audit-source "* && " $WIZ_LIBS " == *" audit-target "* ]] && echo yes || echo no)" "yes"
LOAD_OUT=$(bash -c '
  export REPO_ROOT="'"$REPO_ROOT"'"
  for l in '"$WIZ_LIBS"'; do source "$REPO_ROOT/lib/${l}.sh" || exit 1; done
  for f in audit_source_full audit_target_full source_account_pairs check_php_parity fix_php_parity; do
    type "$f" >/dev/null 2>&1 || { echo "undefined: $f"; exit 1; }
  done
  echo loaded' 2>&1)
check "all wizard libraries load and define the functions the wizard calls" "$LOAD_OUT" "loaded"
SYNTAX_BAD=""
for _f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/tests/run-tests.sh; do
  bash -n "$_f" 2>/dev/null || SYNTAX_BAD+="$(basename "$_f") "
done
check "every script parses" "${SYNTAX_BAD:-none}" "none"

# ---------------------------------------------------------------------------
group "Repository hygiene: nothing credential-shaped is committed"
CRED_HITS=$(grep -rEn 'BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}' \
  "$REPO_ROOT" --exclude-dir=.git 2>/dev/null | head -3)
check "no private keys or API tokens in any file" "${CRED_HITS:-none}" "none"
IP_HITS=$(grep -rEno '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$REPO_ROOT" --exclude-dir=.git 2>/dev/null \
  | grep -vE ':(127\.0\.0\.1|0\.0\.0\.0|1\.1\.1\.1|1\.2\.3\.4|8\.8\.8\.8|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)$' \
  | head -3)
check "no real IP addresses (only well-known/documentation ones)" "${IP_HITS:-none}" "none"
EXAMPLE_FILLED=$(grep -E '^[A-Z_]+=.+' "$REPO_ROOT/config/config.example.env" | grep -vE '^[A-Z_]+=(22|root)$' | head -3)
check "config.example.env ships with every value blank" "${EXAMPLE_FILLED:-none}" "none"
check ".gitignore keeps every real env file out" \
  "$(grep -qF 'config/*.env' "$REPO_ROOT/.gitignore" && grep -qF '!config/config.example.env' "$REPO_ROOT/.gitignore" && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
group "php.ini value comparison"
check "256M in bytes"                  "$(ini_to_num 256M)"  "268435456"
check "2G in bytes"                    "$(ini_to_num 2G)"    "2147483648"
check "512K in bytes"                  "$(ini_to_num 512K)"  "524288"
check "plain integer passes through"   "$(ini_to_num 300 max_execution_time)" "300"
check "-1 means unlimited"             "$(ini_to_num -1 memory_limit)" "9999999999999"
check "max_execution_time 0 = unlimited" "$(ini_to_num 0 max_execution_time)" "9999999999999"
check "memory_limit 0 is not unlimited"  "$(ini_to_num 0 memory_limit)" "0"
check "garbage yields nothing"         "$(ini_to_num 'lots')" ""
check "unlimited outranks any finite limit" \
  "$([[ "$(ini_to_num -1 memory_limit)" -gt "$(ini_to_num 4G memory_limit)" ]] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
group "Disk headroom"
check "fits with margin"        "$(disk_headroom_ok 1000 1200 && echo yes || echo no)" "yes"
check "exact fit fails margin"  "$(disk_headroom_ok 1000 1000 && echo yes || echo no)" "no"
check "non-numeric is refused"  "$(disk_headroom_ok abc 1000 && echo yes || echo no)" "no"

# ---------------------------------------------------------------------------
group "Source discovery"
# These override the fixture paths read by lib/audit-source.sh, which is sourced above.
# shellcheck disable=SC2034
mkdir -p "$TMP/src" "$TMP/src/users" "$TMP/src/valiases"
printf 'example.com: alice\nshop.example.org: bob\norphan.example.net: nobody\nsys.example.io: root\n' > "$TMP/src/trueuserdomains"
SRC_TRUEUSERDOMAINS_FILE="$TMP/src/trueuserdomains"
check "account pairs skip root/nobody and are sorted" \
  "$(source_account_pairs | tr '\n' ',')" "example.com alice,shop.example.org bob,"

printf 'DNS=fallback.example.com\nUSER=carol\n' > "$TMP/src/users/carol"
printf 'DNS=ignored.example.com\n' > "$TMP/src/users/root"
SRC_TRUEUSERDOMAINS_FILE="$TMP/src/does-not-exist"
# shellcheck disable=SC2034
SRC_CPANEL_USERS_DIR="$TMP/src/users"
check "falls back to /var/cpanel/users when trueuserdomains is absent" \
  "$(source_account_pairs | tr '\n' ',')" "fallback.example.com carol,"
# shellcheck disable=SC2034
SRC_TRUEUSERDOMAINS_FILE="$TMP/src/trueuserdomains"

printf 'alice.example.com: alice==root==addon==example.com==/home/alice/a==x==y\nex.com: alice==root==main==ex.com==/home/alice/public_html==x==y\nbob.example.com: bob==root==addon==shop.example.org==/home/bob/a==x==y\n' > "$TMP/src/userdatadomains"
# shellcheck disable=SC2034
SRC_USERDATADOMAINS_FILE="$TMP/src/userdatadomains"
check "addon domains are listed for the right account only" \
  "$(source_extra_domains alice | tr -d '[:space:]')" "alice.example.com"

printf '*: :fail: No Such User Here\n' > "$TMP/src/valiases/example.com"
printf '*: catchall@shop.example.org\ninfo: real@shop.example.org\n' > "$TMP/src/valiases/shop.example.org"
# shellcheck disable=SC2034
SRC_VALIASES_DIR="$TMP/src/valiases"
check "default reject is not a catch-all" "$(classify_catchall "$(detect_catchall example.com)")" "none"
check "a real catch-all is reported with its destination" \
  "$(classify_catchall "$(detect_catchall shop.example.org)")" "forward:catchall@shop.example.org"
check "blackhole is not a catch-all" "$(classify_catchall ':blackhole:')" "none"
check "no valiases file -> none" "$(classify_catchall "$(detect_catchall missing.example.com)")" "none"

mkdir -p "$TMP/plat/wp" "$TMP/plat/lara/public" "$TMP/plat/joom" "$TMP/plat/php" "$TMP/plat/static" "$TMP/plat/empty"
: > "$TMP/plat/wp/wp-config.php"
: > "$TMP/plat/lara/artisan"
printf '<?php class JConfig {}\n' > "$TMP/plat/joom/configuration.php"
: > "$TMP/plat/php/index.php"
: > "$TMP/plat/static/index.html"
check "platform: WordPress"          "$(detect_platform "$TMP/plat/wp")"            "WordPress"
check "platform: Laravel (artisan one level above public/)" "$(detect_platform "$TMP/plat/lara/public")" "Laravel"
check "platform: Joomla"             "$(detect_platform "$TMP/plat/joom")"          "Joomla"
check "platform: generic PHP"        "$(detect_platform "$TMP/plat/php")"           "PHP"
check "platform: static"             "$(detect_platform "$TMP/plat/static")"        "static"
check "platform: unknown"            "$(detect_platform "$TMP/plat/empty")"         "unknown"

# ---------------------------------------------------------------------------
group "PHP parity check and fix"
export AUDIT_DIR="$TMP/audit"
printf 'memory_limit=512M\nupload_max_filesize=128M\nmax_execution_time=300\n' > "$AUDIT_DIR/source-php-limits.env"

check "lower target limits are flagged" \
  "$( ( php_limits_of() { printf 'memory_limit=128M\nupload_max_filesize=128M\nmax_execution_time=300\n'; }; check_php_parity >/dev/null 2>&1; echo $? ) )" "1"
check "equal limits pass" \
  "$( ( php_limits_of() { printf 'memory_limit=512M\nupload_max_filesize=128M\nmax_execution_time=300\n'; }; check_php_parity >/dev/null 2>&1; echo $? ) )" "0"
check "higher target limits pass (never asks to lower anything)" \
  "$( ( php_limits_of() { printf 'memory_limit=2G\nupload_max_filesize=1G\nmax_execution_time=0\n'; }; check_php_parity >/dev/null 2>&1; echo $? ) )" "0"
check "unlimited (-1) on the target passes" \
  "$( ( php_limits_of() { printf 'memory_limit=-1\nupload_max_filesize=128M\nmax_execution_time=300\n'; }; check_php_parity >/dev/null 2>&1; echo $? ) )" "0"
check "an unreadable target is reported as 'cannot check' (2), not a pass or a gap" \
  "$( ( php_limits_of() { :; }; check_php_parity >/dev/null 2>&1; echo $? ) )" "2"

mkdir -p "$TMP/phpd/a" "$TMP/phpd/b"
DROP="$TMP/phpd/a/${TARGET_PHP_INI_NAME}"
FIX_OUT=$( (
  TARGET_PHP_INI_DIRS="$TMP/phpd/a $TMP/phpd/b"
  php_limits_of() {
    if [[ -f "$DROP" ]]; then sed 's/ *= */=/' "$DROP"; else printf 'memory_limit=128M\nupload_max_filesize=2M\nmax_execution_time=30\n'; fi
  }
  fix_php_parity >/dev/null 2>&1; echo "rc=$?"
  fix_php_parity >/dev/null 2>&1; echo "second-rc=$?"
) )
check "fix_php_parity raises the limits and re-verifies (rc 0)" "$(printf '%s' "$FIX_OUT" | sed -n 's/^rc=//p')" "0"
check "drop-in has the raised values" "$(tr -d ' ' < "$DROP" | tr '\n' ',')" "memory_limit=512M,upload_max_filesize=128M,max_execution_time=300,"
check "drop-in written to every configured directory" "$([[ -f "$TMP/phpd/b/${TARGET_PHP_INI_NAME}" ]] && echo yes || echo no)" "yes"
check "running the fix again is a no-op and stays successful" "$(printf '%s' "$FIX_OUT" | sed -n 's/^second-rc=//p')" "0"
check "no backup clutter when nothing changed" "$(compgen -G "$TMP/phpd/a/*.bak.*" | wc -l | tr -d '[:space:]')" "0"
check "fix refuses to run with no recorded source limits" \
  "$( ( AUDIT_DIR="$TMP/empty-audit"; mkdir -p "$AUDIT_DIR"; fix_php_parity >/dev/null 2>&1; echo $? ) )" "1"
check "fix reports failure when no PHP config directory exists" \
  "$( ( export TARGET_PHP_INI_DIRS="$TMP/nowhere/*"; php_limits_of() { printf 'memory_limit=128M\n'; }; fix_php_parity >/dev/null 2>&1; echo $? ) )" "1"


# ---------------------------------------------------------------------------
group "IPv4 validation (DNS needs an address, not a hostname)"
check "real address accepted"            "$(is_ipv4 203.0.113.9 && echo yes || echo no)" "yes"
check "hostname rejected"                "$(is_ipv4 vmi123.contaboserver.net && echo yes || echo no)" "no"
check "octet over 255 rejected"          "$(is_ipv4 "$((299 + 1)).1.1.1" && echo yes || echo no)" "no"
check "too few octets rejected"          "$(is_ipv4 1.2.3 && echo yes || echo no)" "no"
check "empty rejected"                   "$(is_ipv4 '' && echo yes || echo no)" "no"

# ---------------------------------------------------------------------------
group "SPF: add this server, keep everything the domain already authorized"
check "no record -> conservative default" "$(spf_rewrite '' 203.0.113.9)" "v=spf1 +mx +a +ip4:203.0.113.9 ~all"
check "include: kept, server added" \
  "$(spf_rewrite 'v=spf1 include:zoho.eu ~all' 203.0.113.9)" "v=spf1 include:zoho.eu +ip4:203.0.113.9 ~all"
check "mx/a/other ip4/include all kept, and the -all policy is NOT loosened to ~all" \
  "$(spf_rewrite 'v=spf1 mx a ip4:198.51.100.7 include:_spf.google.com -all' 203.0.113.9)" \
  "v=spf1 mx a ip4:198.51.100.7 include:_spf.google.com +ip4:203.0.113.9 -all"
check "redirect= record is returned untouched" \
  "$(spf_rewrite 'v=spf1 redirect=_spf.example.net' 203.0.113.9)" "v=spf1 redirect=_spf.example.net"
check "already authorized -> unchanged, no duplicate ip4" \
  "$(spf_rewrite 'v=spf1 +ip4:203.0.113.9 ~all' 203.0.113.9)" "v=spf1 +ip4:203.0.113.9 ~all"

# ---------------------------------------------------------------------------
group "Contabo DNS: real error handling, against a fake API"
CURL_LOG="$TMP/curl.log"
DNS_RECORDS='{"data":[
 {"recordId":22,"name":"example.com","type":"TXT","data":"google-site-verification=abc","ttl":3600,"prio":0},
 {"recordId":21,"name":"example.com","type":"TXT","data":"v=spf1 include:zoho.eu ~all","ttl":300,"prio":0},
 {"recordId":11,"name":"example.com","type":"A","data":"198.51.100.7","ttl":600,"prio":0},
 {"recordId":12,"name":"www.example.com","type":"A","data":"198.51.100.7","ttl":600,"prio":0},
 {"recordId":31,"name":"example.com","type":"MX","data":"mail.example.com","ttl":3600,"prio":10}]}'
# A stand-in for curl that logs "METHOD URL BODY" and answers "<body>\n<http code>",
# the shape _contabo_call asks for with -w. FAKE_API picks the scenario.
fake_curl() {
  local method=GET url="" body="" prev="" a
  for a in "$@"; do
    case "$prev" in -X) method="$a" ;; -d) body="$a" ;; esac
    case "$a" in http*) url="$a" ;; esac
    prev="$a"
  done
  printf '%s %s %s\n' "$method" "$url" "$body" >> "$CURL_LOG"
  case "$url" in
    # contabo_token does not ask curl for a status code (-w), so it gets a bare body.
    *openid-connect*) printf '{"access_token":"tok"}'; return 0 ;;
  esac
  case "${FAKE_API:-ok}" in
    zone-missing) printf '{"message":"zone not found"}\n404' ;;
    patch-fails)
      if [[ "$method" == "GET" ]]; then printf '%s\n200' "$DNS_RECORDS"; else printf '{"message":"invalid data"}\n400'; fi ;;
    *)
      if [[ "$method" == "GET" ]]; then printf '%s\n200' "$DNS_RECORDS"; else printf '{"data":[]}\n200'; fi ;;
  esac
}
dns_run() {  # dns_run <scenario> <ip> ; prints the exit status
  ( : > "$CURL_LOG"
    export FAKE_API="$1" CONTABO_CLIENT_ID=i CONTABO_CLIENT_SECRET=s CONTABO_API_USER=u CONTABO_API_PASSWORD=p
    curl() { fake_curl "$@"; }
    wait_for_propagation() { return 0; }
    dns_cutover_domain example.com "$2" >/dev/null 2>&1; echo $? )
}
check "cutover succeeds against a healthy API" "$(dns_run ok 203.0.113.9)" "0"
check "the apex A record is updated by its own id, keeping its 600s TTL" \
  "$(grep -c 'PATCH .*/records/11 .*"ttl": 600' "$CURL_LOG")" "1"
check "the real SPF record (id 21) is updated, keeping its 300s TTL" \
  "$(grep -c 'PATCH .*/records/21 .*include:zoho.eu +ip4:203.0.113.9 ~all.*"ttl": 300' "$CURL_LOG")" "1"
check "the site-verification TXT record (listed first) is never touched" \
  "$(grep -c '/records/22' "$CURL_LOG" | tr -d ' ')" "0"
check "no record is created when one already exists" "$(grep -c '^POST https://api.contabo.com' "$CURL_LOG" | tr -d ' ')" "0"
check "an unreadable zone stops the cutover" "$(dns_run zone-missing 203.0.113.9)" "1"
check "...before a single record is written" "$(grep -cE '^(POST|PATCH|DELETE) https://api.contabo.com' "$CURL_LOG" | tr -d ' ')" "0"
check "a rejected update is reported as a failure, not 'DNS updated'" "$(dns_run patch-fails 203.0.113.9)" "1"
check "a hostname instead of an IPv4 is refused" "$(dns_run ok vmi123.contaboserver.net)" "1"
check "...without calling the API at all" "$(wc -l < "$CURL_LOG" | tr -d ' ')" "0"
check "_contabo_call surfaces the API's own message on failure" \
  "$( ( curl() { printf '{"message":"quota exceeded"}\n429'; }; _contabo_call GET http://x tok 2>&1 >/dev/null ) | sed 's/\x1b\[[0-9;]*m//g' )" \
  "[!!] Contabo API GET failed (HTTP 429): quota exceeded"

# ---------------------------------------------------------------------------
group "Database users: exact passwords, no shell quoting, never passwordless"
check "sql_quote doubles quotes and backslashes" "$(sql_quote "it's a\\b")" "'it''s a\\\\b'"
check "identifier with a backtick is escaped" "$(ident_quote 'a`b')" '`a``b`'
SQL_OUT=$(build_db_user_sql 'my-db' "app'user" "p'a\\ss\$x")
check "user SQL carries the password byte-for-byte (escaped for SQL only)" \
  "$(printf '%s\n' "$SQL_OUT" | grep -c "IDENTIFIED BY 'p''a\\\\\\\\ss\$x';")" "4"
check "user SQL covers both localhost and 127.0.0.1" \
  "$(printf '%s\n' "$SQL_OUT" | grep -c "@'127.0.0.1'")" "3"
check "an existing user's password is corrected (ALTER USER), not left as it was" \
  "$(printf '%s\n' "$SQL_OUT" | grep -c '^ALTER USER')" "2"
check "create_db_user sends the SQL on stdin" \
  "$( ( c_ssh_pipe() { cat > "$TMP/sent.sql"; }; create_db_user d u "pa'ss" >/dev/null 2>&1; grep -c "IDENTIFIED BY 'pa''ss'" "$TMP/sent.sql" ) )" "4"
check "create_db_user refuses an empty password (no passwordless MySQL user)" \
  "$( ( c_ssh_pipe() { cat > "$TMP/sent2.sql"; }; create_db_user d u '' >/dev/null 2>&1; rc=$?; echo "rc=$rc sent=$([[ -f "$TMP/sent2.sql" ]] && wc -c < "$TMP/sent2.sql" || echo 0)" ) | tr -s ' ' )" "rc=1 sent=0"

# ---------------------------------------------------------------------------
group "Connection probe: password travels in MYSQL_PWD, never as an argument"
export MOCK_MYSQL_ARGV_LOG="$TMP/mysql-argv.log"; : > "$MOCK_MYSQL_ARGV_LOG"
probe() { _db_connect_probe_script | { printf 'user=%q; pass=%q; db=%q\n' appuser "$1" appdb; cat; } | c_ssh_pipe target "bash -s"; }
export EXPECT_PWD="s3cr'et\$1"
check "right password -> connects" "$(probe "s3cr'et\$1")" "yes"
check "wrong password -> refused" "$(probe 'nope')" "no"
check "the password never appears in mysql's argument list" \
  "$(grep -c "s3cr" "$MOCK_MYSQL_ARGV_LOG" | tr -d ' ')" "0"
unset EXPECT_PWD MOCK_MYSQL_ARGV_LOG

# ---------------------------------------------------------------------------
group "Dump charset: never latin1 for data that is not latin1"
check "utf8 (mb3) tables -> utf8mb4 (latin1 would turn ă ș ț into '?')" "$(pick_dump_charset utf8)"   "utf8mb4"
check "utf8mb4 tables -> utf8mb4"        "$(pick_dump_charset utf8mb4)"       "utf8mb4"
check "pure latin1 stays latin1 (byte-exact)" "$(pick_dump_charset latin1)"   "latin1"
check "cp1250 keeps its own charset"     "$(pick_dump_charset cp1250)"        "cp1250"
check "mixed charsets -> utf8mb4"        "$(pick_dump_charset 'latin1 utf8mb4')" "utf8mb4"
check "no tables -> utf8mb4"             "$(pick_dump_charset '')"            "utf8mb4"
check "an odd value is not passed through to a shell/SQL" "$(pick_dump_charset 'x;drop')" "utf8mb4"
dump_cmd_for() {  # dump_cmd_for <table charsets> ; prints the mysqldump/CREATE DATABASE lines issued
  ( : > "$TMP/cmds.log"
    c_ssh()      { printf '%s\n' "$*" >> "$TMP/cmds.log"; case "$*" in *character_set_name*) echo "$1x" >/dev/null; printf '%s\n' "$CHARSETS_FAKE" ;; *) echo 5 ;; esac; }
    c_ssh_pipe() { cat >/dev/null; printf '%s\n' "$*" >> "$TMP/cmds.log"; }
    CHARSETS_FAKE="$1" migrate_one_database example.com wp_db wpuser 'pw' >/dev/null 2>&1
    grep -oE '(mysqldump --default-character-set=[a-z0-9]+|CHARACTER SET [a-z0-9]+)' "$TMP/cmds.log" | tr '\n' ',' )
}
check "a utf8 database is dumped and created as utf8mb4" \
  "$(dump_cmd_for utf8)" "CHARACTER SET utf8mb4,mysqldump --default-character-set=utf8mb4,"
check "a latin1 database is still dumped as latin1" \
  "$(dump_cmd_for latin1)" "CHARACTER SET latin1,mysqldump --default-character-set=latin1,"

# ---------------------------------------------------------------------------
group "Database selection: one account never picks up another's databases"
check "prefix SQL matches the literal '<user>_' prefix" \
  "$(prefixed_dbs_sql web)" "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SUBSTRING(SCHEMA_NAME,1,4)='web_';"
check "prefix SQL does not use LIKE (where _ is a wildcard)" "$(prefixed_dbs_sql web | grep -ci 'like' | tr -d ' ')" "0"
PD_OUT=$( (
  discover_app_db_credentials() { printf 'web_wp\tweb_user\tpw\n'; }
  c_ssh() { case "$*" in *SUBSTRING*) printf 'web_wp\nweb_shop\n' ;; *"SCHEMA_NAME='web_wp'"*) echo web_wp ;; esac; }
  migrate_one_database() { echo "MIGRATED:$2" >> "$TMP/migrated.log"; }
  : > "$TMP/migrated.log"
  phase_migrate_database example.com web web 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -c 'web_shop'
  cat "$TMP/migrated.log" | tr '\n' ','
) )
check "an extra database is named in a warning, not silently left behind" "$(printf '%s' "$PD_OUT" | head -1)" "1"
check "only the app's own database is migrated" "$(printf '%s' "$PD_OUT" | tail -1)" "MIGRATED:web_wp,"

# ---------------------------------------------------------------------------
group "Mailbox password hash: exact match on the local part"
mkdir -p "$TMP/home/alice/etc/example.com"
printf 'john.smith:HASH-DOT:1:2\njohn-smith:HASH-DASH:1:2\njohnXsmith:HASH-X:1:2\ninfo:HASH-INFO:1:2\n' > "$TMP/home/alice/etc/example.com/shadow"
export SRC_HOME_BASE="$TMP/home"
check "a dotted name returns its own hash, not a lookalike's" "$(source_mail_hash alice example.com john.smith)" "HASH-DOT"
check "a plain name still works" "$(source_mail_hash alice example.com info)" "HASH-INFO"
check "a missing mailbox returns nothing" "$(source_mail_hash alice example.com nobody)" ""
check "a missing domain returns nothing" "$(source_mail_hash alice nowhere.example john.smith)" ""
unset SRC_HOME_BASE

# ---------------------------------------------------------------------------
group "Wizard: a failed migration is never followed by DNS cutover"
# The variables set inside are read by step_migrate in the sourced wizard.
# shellcheck disable=SC2034
wiz_run() {  # wiz_run <accounts, one 'domain user' per line> ; prints "rc=<n> dns=<domains> sanity=<domains>"
  ( export REPO_ROOT
    # shellcheck source=../bin/migrate-wizard.sh
    source "$REPO_ROOT/bin/migrate-wizard.sh"
    AUDIT_DIR="$TMP/wizaudit"; mkdir -p "$AUDIT_DIR"
    DO_DNS_CUTOVER=1; TARGET_PUBLIC_IP=203.0.113.9; ACCOUNT_LIST="$1"
    : > "$TMP/wiz.log"
    confirm()             { return 0; }
    migrate_account()     { [[ "$1" != bad.example.com ]]; }
    dns_cutover_domain()  { echo "DNS:$1" >> "$TMP/wiz.log"; }
    request_certificate() { :; }
    sanity_check_domain() { echo "SANITY:$1" >> "$TMP/wiz.log"; }
    sanity_report_summary() { :; }
    step_migrate >/dev/null 2>&1; rc=$?
    echo "rc=$rc dns=$(grep '^DNS:' "$TMP/wiz.log" | tr '\n' ' ')sanity=$(grep '^SANITY:' "$TMP/wiz.log" | tr '\n' ' ')" )
}
check "DNS and sanity run only for the account that migrated; exit status is non-zero" \
  "$(wiz_run $'good.example.com goodu\nbad.example.com badu')" \
  "rc=1 dns=DNS:good.example.com sanity=SANITY:good.example.com "
check "a fully successful run exits 0" \
  "$(wiz_run $'good.example.com goodu')" "rc=0 dns=DNS:good.example.com sanity=SANITY:good.example.com "

# ---------------------------------------------------------------------------
printf '\n\033[1mResult:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
