#!/usr/bin/env bash
# common.sh — shared helpers for contabo-panel-migrator
#
# Sourced by every other script. Provides logging, safe SSH wrappers, and
# the handful of "gotcha" workarounds discovered the hard way during a real
# cPanel -> Virtualmin (Webmin+LAMP) migration:
#
#   * SSH inside a `while read` loop steals the loop's stdin unless the call
#     redirects it — c_ssh() does this for you. When you deliberately need
#     to *pipe data into* a remote command (a database import, say), use
#     c_ssh_pipe() instead: c_ssh() would discard that data.
#   * rsync on some providers refuses source-and-destination-both-remote,
#     so file transfers always go through a local staging directory or a
#     `tar | ssh ... tar -x` pipe.
#   * Virtualmin's own `--multiline` CLI output is indented with leading
#     whitespace, which silently breaks an anchored `grep "^Field:"` — use
#     vm_field() below instead of grepping multiline output yourself.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'

log()       { printf "%b[*]%b %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()        { printf "%b[OK]%b %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn()      { printf "%b[!!]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()       { printf "%b[XX]%b %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
section()   { printf "\n%b== %s ==%b\n" "$C_BOLD" "$*" "$C_RESET"; }
die()       { err "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Checks everything this toolkit shells out to, up front, rather than
# failing three hours into a migration because `dig` isn't installed.
preflight_local_deps() {
  local missing=()
  local cmd
  for cmd in ssh rsync tar curl python3 openssl base64; do
    have_cmd "$cmd" || missing+=("$cmd")
  done
  if ! have_cmd dig && ! have_cmd host && ! have_cmd nslookup; then
    missing+=("dig (or host/nslookup)")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required local commands: ${missing[*]}"
    err "Install them and re-run. On Debian/Ubuntu:"
    err "  apt install openssh-client rsync tar curl python3 openssl coreutils dnsutils"
    err "On macOS (most are preinstalled): brew install rsync bind"
    return 1
  fi
  return 0
}

# Resolves a hostname's A record using whichever DNS client is available.
resolve_a_record() {
  local domain="$1" resolver="${2:-1.1.1.1}"
  if have_cmd dig; then
    dig "@${resolver}" +short "$domain" A 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | tail -1
  elif have_cmd host; then
    host -t A "$domain" "$resolver" 2>/dev/null | awk '/has address/ {print $NF}' | tail -1
  elif have_cmd nslookup; then
    nslookup -type=A "$domain" "$resolver" 2>/dev/null | awk '/^Address: / {print $2}' | tail -1
  fi
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------
# Loads config/config.env (or the path in $1) if present. Never fails the
# script if the file is missing — the wizard prompts for anything unset.
load_config() {
  local cfg="${1:-$REPO_ROOT/config/config.env}"
  if [[ -f "$cfg" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$cfg"; set +a
    log "Loaded config from $cfg"
  fi
}

# Prompts for a variable if it isn't already set (from config.env or env).
# Usage: ask VAR_NAME "Prompt text" ["default"] [secret]
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __secret="${4:-}"
  local __current="${!__var:-}"
  if [[ -n "$__current" ]]; then return 0; fi
  local __input=""
  if [[ "$__secret" == "secret" ]]; then
    read -r -s -p "$__prompt${__default:+ [$__default]}: " __input </dev/tty; echo
  else
    read -r -p "$__prompt${__default:+ [$__default]}: " __input </dev/tty
  fi
  printf -v "$__var" '%s' "${__input:-$__default}"
  export "${__var?}"
}

confirm() {
  local prompt="${1:-Continue?}" reply
  read -r -p "$prompt [y/N]: " reply </dev/tty
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# SSH / remote execution
# ---------------------------------------------------------------------------
# Builds the ssh option array for a role. Note that BatchMode is only set
# when an explicit key was configured: with BatchMode=yes and no key, ssh
# refuses to prompt for a password at all, so a password-auth setup would
# fail with a confusing "Permission denied (publickey)" instead of asking.
_ssh_opts_for() {
  local role="$1"
  local port key
  case "$role" in
    source) port="${SOURCE_SSH_PORT:-22}"; key="${SOURCE_SSH_KEY:-}" ;;
    target) port="${TARGET_SSH_PORT:-22}"; key="${TARGET_SSH_KEY:-}" ;;
    *) die "_ssh_opts_for: unknown role '$role' (expected source|target)" ;;
  esac
  _SSH_OPTS=(-p "$port" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
  if [[ -n "$key" ]]; then
    _SSH_OPTS+=(-i "$key" -o BatchMode=yes)
  fi
}

_ssh_userhost_for() {
  local role="$1"
  case "$role" in
    source) printf '%s@%s' "${SOURCE_SSH_USER:-root}" "${SOURCE_HOST:?SOURCE_HOST is not set}" ;;
    target) printf '%s@%s' "${TARGET_SSH_USER:-root}" "${TARGET_HOST:?TARGET_HOST is not set}" ;;
  esac
}

# c_ssh <source|target> "<remote command>"
#
# The `</dev/null` is not optional: any c_ssh call may run inside a
# `while read` loop, and ssh would otherwise read (and silently drain) that
# loop's stdin, making the loop appear to process only its first item.
c_ssh() {
  local role="$1"; shift
  local -a _SSH_OPTS
  _ssh_opts_for "$role"
  ssh "${_SSH_OPTS[@]}" "$(_ssh_userhost_for "$role")" "$@" </dev/null
}

# c_ssh_pipe <source|target> "<remote command>"
#
# Identical to c_ssh but leaves stdin connected, so data can be piped into
# the remote command (e.g. `mysqldump ... | c_ssh_pipe target "mysql db"`).
# Using c_ssh there instead would silently feed the remote command an empty
# stdin and "succeed" while importing nothing at all.
c_ssh_pipe() {
  local role="$1"; shift
  local -a _SSH_OPTS
  _ssh_opts_for "$role"
  ssh "${_SSH_OPTS[@]}" "$(_ssh_userhost_for "$role")" "$@"
}

# Two-hop copy: source -> local staging -> target. Many rsync builds refuse
# a both-ends-remote invocation outright, and the source and target should
# never have standing SSH trust in each other anyway.
c_relay_copy() {
  local remote_src_path="$1" local_stage_dir="$2" remote_dst_path="$3"
  mkdir -p "$local_stage_dir"
  local -a src_opts dst_opts
  _ssh_opts_for source; src_opts=("${_SSH_OPTS[@]}")
  _ssh_opts_for target; dst_opts=("${_SSH_OPTS[@]}")

  log "Pulling $remote_src_path from source..."
  rsync -az --info=progress2 -e "ssh ${src_opts[*]}" \
    "$(_ssh_userhost_for source):${remote_src_path%/}/" \
    "${local_stage_dir%/}/" || return 1

  log "Pushing to target at $remote_dst_path..."
  rsync -az --info=progress2 -e "ssh ${dst_opts[*]}" \
    "${local_stage_dir%/}/" \
    "$(_ssh_userhost_for target):${remote_dst_path%/}/"
}

# Streams a tar archive straight from source to target through this
# machine, with no intermediate disk copy. Preferred for Maildir transfers.
#
# Usage: c_relay_tar <src-dir> <dst-dir> [tar-option]...
# Each extra argument is passed to the remote tar as a single, separately
# quoted argument — so `--exclude=*.log` reaches tar intact instead of
# being glob-expanded by the remote shell against the wrong directory.
c_relay_tar() {
  local remote_src_path="$1" remote_dst_path="$2"; shift 2
  local -a src_opts dst_opts
  _ssh_opts_for source; src_opts=("${_SSH_OPTS[@]}")
  _ssh_opts_for target; dst_opts=("${_SSH_OPTS[@]}")

  # $# guard: see the note in remote_script — bash 3.2 (macOS) aborts on an
  # empty "$@" under `set -u`.
  local tar_opts="" o
  if [[ $# -gt 0 ]]; then
    for o in "$@"; do
      tar_opts+=" $(printf '%q' "$o")"
    done
  fi

  ssh "${src_opts[@]}" "$(_ssh_userhost_for source)" \
      "tar${tar_opts} -cf - -C $(printf '%q' "$remote_src_path") ." </dev/null | \
  ssh "${dst_opts[@]}" "$(_ssh_userhost_for target)" \
      "mkdir -p $(printf '%q' "$remote_dst_path") && tar -xf - -C $(printf '%q' "$remote_dst_path")"
}

# Runs a multi-line script on a remote host with no quoting hell at all:
# the script is base64-encoded locally and decoded remotely, so quotes,
# `$`, backticks and globs inside it are never touched by either shell.
# This is the antidote to the nested-quoting class of bug (a password
# containing `$` silently corrupted by `ssh ... 'mysql -e "..."'`).
#
# Usage:  remote_script target [args...] <<'EOF'
#           echo "$1"
#         EOF
remote_script() {
  local role="$1"; shift
  local script b64
  script=$(cat)
  b64=$(printf '%s' "$script" | base64 | tr -d '\n')
  # Guarded on $# rather than iterating "$@" directly: bash 3.2, which is
  # still what macOS ships as /bin/bash, treats an empty "$@" as an unbound
  # variable under `set -u` and aborts.
  local args="" a
  if [[ $# -gt 0 ]]; then
    for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  fi
  c_ssh "$role" "echo '${b64}' | base64 -d | bash -s --${args}"
}

# ---------------------------------------------------------------------------
# Virtualmin CLI helpers
# ---------------------------------------------------------------------------
# Extracts one field from `virtualmin ... --multiline` output, tolerating
# the module's leading-whitespace indentation (a bare `grep "^Field:"`
# silently matches nothing, and a loop over it runs zero times with no
# error at all — which looks exactly like a loop that worked).
vm_field() {
  local field="$1"
  sed -n "s/^[[:space:]]*${field}:[[:space:]]*//p" | head -1
}

# Tolerant sed-based config edit: matches `key = value`, `key=value`, and
# any amount of surrounding whitespace, instead of assuming one exact
# spacing style. Always re-read the value afterwards to confirm it took.
c_set_kv() {
  local file="$1" key="$2" value="$3"
  sed -i -E "s/^[[:space:]]*${key}[[:space:]]*=.*/${key}=${value}/" "$file"
}

# Total real row count for a database, summed across every base table.
# Deliberately NOT information_schema.table_rows — that is an *estimate*
# for InnoDB and is routinely stale immediately after an import, which
# makes it useless for exactly the verification we need it for.
db_total_rows() {
  local role="$1" db="$2"
  local inner
  inner=$(c_ssh "$role" "mysql -N -B -e \"SET SESSION group_concat_max_len=10000000; SELECT GROUP_CONCAT(CONCAT('SELECT COUNT(*) AS c FROM \\\`', table_schema, '\\\`.\\\`', table_name, '\\\`') SEPARATOR ' UNION ALL ') FROM information_schema.tables WHERE table_schema='${db}' AND table_type='BASE TABLE';\"" 2>/dev/null)
  [[ -z "$inner" || "$inner" == "NULL" ]] && { echo 0; return; }
  c_ssh "$role" "mysql -N -B -e \"SELECT COALESCE(SUM(c),0) FROM (${inner}) x;\"" 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Audit helpers (shared by lib/audit-source.sh and lib/audit-target.sh)
# ---------------------------------------------------------------------------
# Every remote probe below goes through remote_script, so nothing in them is
# ever exposed to nested-quoting problems. All of them are strictly read-only.

# remote_missing_tools <source|target> <tool>...
# Prints, space-separated, whichever of the named commands are NOT installed
# on the remote host. Empty output means everything is present.
remote_missing_tools() {
  local role="$1"; shift
  [[ $# -gt 0 ]] || return 0
  remote_script "$role" "$@" <<'SCRIPT_EOF'
for t in "$@"; do
  command -v "$t" >/dev/null 2>&1 || printf '%s ' "$t"
done
exit 0
SCRIPT_EOF
}

# detect_security_stack <source|target>
# Prints the names of any host-security layers found, space-separated. These
# matter for a migration because several of them (CSF, Imunify360, cPHulk,
# fail2ban) will happily rate-limit or ban the machine running the wizard
# in the middle of a large transfer.
detect_security_stack() {
  remote_script "$1" <<'SCRIPT_EOF'
found=""
add() { found="$found $1"; }
if [ -x /usr/sbin/csf ] || [ -f /etc/csf/csf.conf ]; then add CSF; fi
if command -v imunify360-agent >/dev/null 2>&1 || [ -x /usr/bin/imunify360-agent ]; then add Imunify360; fi
if [ -e /var/cpanel/hulkd/enabled ]; then add cPHulk; fi
if [ -d /etc/apache2/conf.d/modsec ] || [ -f /etc/apache2/conf.d/modsec2.conf ] \
   || [ -f /usr/local/apache/conf/modsec2.conf ] \
   || ls /etc/httpd/conf.d/*security2* >/dev/null 2>&1 \
   || [ -e /etc/apache2/mods-enabled/security2.load ]; then add ModSecurity; fi
if command -v fail2ban-client >/dev/null 2>&1; then add fail2ban; fi
if command -v clamscan >/dev/null 2>&1 || [ -x /usr/local/cpanel/3rdparty/bin/clamscan ]; then add ClamAV; fi
echo "${found# }"
SCRIPT_EOF
}

# php_limits_of <source|target>
# Prints key=value lines for the PHP resource limits that most often differ
# between a cPanel box and a fresh PHP-FPM install. Read from the php CLI;
# a per-domain override (MultiPHP INI editor, a pool file) is NOT visible here.
php_limits_of() {
  remote_script "$1" <<'SCRIPT_EOF'
for k in memory_limit upload_max_filesize post_max_size max_execution_time max_input_vars; do
  v=$(php -r "echo ini_get('$k');" 2>/dev/null </dev/null)
  if [ -n "$v" ]; then printf '%s=%s\n' "$k" "$v"; fi
done
exit 0
SCRIPT_EOF
}

# ini_to_num <value> [key]
# Converts a php.ini value to a plain integer so two values can be compared:
# "256M" -> bytes, "-1" (and max_execution_time=0) -> a huge number meaning
# "unlimited". Prints nothing for anything unparseable.
ini_to_num() {
  local v="${1:-}" key="${2:-}" n suffix
  v="${v//[[:space:]]/}"
  [[ -z "$v" ]] && return 0
  if [[ "$v" == "-1" || ( "$key" == "max_execution_time" && "$v" == "0" ) ]]; then
    echo 9999999999999
    return 0
  fi
  if [[ "$v" =~ ^([0-9]+)([KkMmGg]?)$ ]]; then
    n="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    case "$suffix" in
      K|k) echo $((n * 1024)) ;;
      M|m) echo $((n * 1024 * 1024)) ;;
      G|g) echo $((n * 1024 * 1024 * 1024)) ;;
      *)   echo "$n" ;;
    esac
  fi
}

# disk_headroom_ok <needed_kb> <free_kb> [percent_margin=10]
# True when free space covers the need plus a safety margin.
disk_headroom_ok() {
  local need="${1:-0}" free="${2:-0}" margin="${3:-10}"
  [[ "$need" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]] || return 1
  [[ $((need * (100 + margin) / 100)) -le "$free" ]]
}

# ---------------------------------------------------------------------------
# Validation and SQL helpers
# ---------------------------------------------------------------------------

# is_ipv4 <value> — true for a dotted-quad IPv4 address (each octet 0-255).
is_ipv4() {
  local ip="${1:-}" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
    [[ $((10#$o)) -le 255 ]] || return 1
  done
}

# sql_quote <string> — prints a MySQL/MariaDB single-quoted string literal.
# Backslashes are doubled and single quotes are doubled, so a password like
#   it's a\b
# reaches the server byte-for-byte instead of ending the string early or
# having "\b" read as a backspace. (Assumes the default sql_mode; a server
# running NO_BACKSLASH_ESCAPES is not supported.)
sql_quote() {
  local esc
  esc=$(printf '%s' "${1-}" | sed -e 's/\\/\\\\/g' -e "s/'/''/g")
  printf "'%s'" "$esc"
}

# ident_quote <name> — prints a backtick-quoted SQL identifier.
ident_quote() {
  local esc
  esc=$(printf '%s' "${1-}" | sed -e 's/`/``/g')
  printf '`%s`' "$esc"
}

# build_db_user_sql <db> <user> <password>
# The SQL that (re)creates an application's DB user on both the 'localhost'
# and '127.0.0.1' hosts (MySQL/MariaDB do not treat them as interchangeable)
# and grants it its own database. ALTER USER runs after CREATE USER IF NOT
# EXISTS so that re-running a migration also corrects a user left behind
# with a different password. Sent to mysql on stdin, never as an argument.
build_db_user_sql() {
  local db="$1" user="$2" pass="$3" host qu qp qd qh
  qu=$(sql_quote "$user"); qp=$(sql_quote "$pass"); qd=$(ident_quote "$db")
  for host in localhost 127.0.0.1; do
    qh=$(sql_quote "$host")
    printf 'CREATE USER IF NOT EXISTS %s@%s IDENTIFIED BY %s;\n' "$qu" "$qh" "$qp"
    printf 'ALTER USER %s@%s IDENTIFIED BY %s;\n' "$qu" "$qh" "$qp"
    printf 'GRANT ALL PRIVILEGES ON %s.* TO %s@%s;\n' "$qd" "$qu" "$qh"
  done
  printf 'FLUSH PRIVILEGES;\n'
}

# prefixed_dbs_sql <cpanel_user>
# cPanel prefixes every database with "<user>_". This matches that literal
# prefix with SUBSTRING(...) = ..., never LIKE: in LIKE the underscore is a
# wildcard and there is no boundary, so account "web" would also pick up
# another account's "webshop_db".
prefixed_dbs_sql() {
  local user="$1"
  printf "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SUBSTRING(SCHEMA_NAME,1,%d)='%s_';" \
    $((${#user} + 1)) "$user"
}

# account_prefixed_dbs <source|target> <cpanel_user> — one database per line.
account_prefixed_dbs() {
  local role="$1" user="$2"
  [[ "$user" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  c_ssh "$role" "mysql -N -B -e \"$(prefixed_dbs_sql "$user")\" 2>/dev/null"
}

# db_charsets <source|target> <db>
# The distinct REAL character sets of a database's tables (from each table's
# own collation, not the schema default), space-separated.
db_charsets() {
  local role="$1" db="$2"
  [[ "$db" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  c_ssh "$role" "mysql -N -B -e \"SELECT DISTINCT c.character_set_name FROM information_schema.tables t JOIN information_schema.collation_character_set_applicability c ON c.collation_name = t.table_collation WHERE t.table_schema='${db}' AND t.table_type='BASE TABLE';\" 2>/dev/null" \
    | tr '\n' ' ' | sed 's/ *$//'
}

# pick_dump_charset <space-separated list from db_charsets>
# Chooses the client character set for mysqldump and the matching import.
#   * exactly one charset  -> that charset. Dumping and importing in the
#     tables' own charset moves the bytes untouched (this is what keeps a
#     latin1-declared database that holds utf8 bytes intact).
#   * utf8 / utf8mb3 / utf8mb4 / utf16 / ucs2 / utf32 -> utf8mb4, the
#     superset, which is lossless for all of them.
#   * several charsets, or none (empty database) -> utf8mb4.
# The one thing this must never do is fall back to latin1 for a database
# that is not latin1: latin1 cannot represent e.g. the Romanian letters
# ă, ș and ț, and the server silently turns each of them into '?'.
pick_dump_charset() {
  local list="${1:-}" n
  n=$(printf '%s' "$list" | wc -w | tr -d '[:space:]')
  if [[ "$n" -ne 1 || ! "$list" =~ ^[a-z0-9_]+$ ]]; then
    echo utf8mb4; return 0
  fi
  case "$list" in
    utf8|utf8mb3|utf8mb4|utf16|utf16le|ucs2|utf32) echo utf8mb4 ;;
    *) echo "$list" ;;
  esac
}
