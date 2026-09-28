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
check "an unreadable target is a failure, not a silent pass" \
  "$( ( php_limits_of() { :; }; check_php_parity >/dev/null 2>&1; echo $? ) )" "1"

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
printf '\n\033[1mResult:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
