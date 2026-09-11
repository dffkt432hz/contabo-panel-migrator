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
printf '\n\033[1mResult:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
