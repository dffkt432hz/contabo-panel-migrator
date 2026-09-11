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
