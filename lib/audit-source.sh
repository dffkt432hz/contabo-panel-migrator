#!/usr/bin/env bash
# audit-source.sh — Step 7a: read-only scan of the source cPanel server.
#
# Nothing in this file changes anything on the source. It answers, before a
# single byte is copied: which accounts exist, what each one runs, which
# database and mailboxes belong to it, how big it is, and what security
# layers might interfere with a long transfer.
#
# Results are printed for the operator and also written to
# $AUDIT_DIR/source-accounts.tsv and $AUDIT_DIR/source-php-limits.env.
# Database PASSWORDS are never printed or written anywhere by the audit.
#
# Globals set for later steps (all plain assignments, so the wizard must call
# audit_source_full directly, not inside a pipe or $(...)):
#   SOURCE_ACCOUNT_COUNT  SOURCE_TOTAL_KB  SOURCE_DB_KB
#
# Discovery is cPanel-specific (/etc/trueuserdomains, uapi, /etc/valiases).
# See "Extending to other source panels" in docs/ARCHITECTURE.md.

# Path overrides exist so the offline tests can aim discovery at a fixture
# tree instead of the real /etc.
SRC_TRUEUSERDOMAINS_FILE="${SRC_TRUEUSERDOMAINS_FILE:-/etc/trueuserdomains}"
SRC_USERDATADOMAINS_FILE="${SRC_USERDATADOMAINS_FILE:-/etc/userdatadomains}"
SRC_CPANEL_USERS_DIR="${SRC_CPANEL_USERS_DIR:-/var/cpanel/users}"
SRC_VALIASES_DIR="${SRC_VALIASES_DIR:-/etc/valiases}"

# ---------------------------------------------------------------------------
# Discovery primitives
# ---------------------------------------------------------------------------

# Prints one "domain cpanel_user" pair per line for every real account.
# /etc/trueuserdomains is authoritative (it excludes root/nobody and system
# users); /var/cpanel/users/<user> (its DNS= line) is the fallback.
source_account_pairs() {
  remote_script source "$SRC_TRUEUSERDOMAINS_FILE" "$SRC_CPANEL_USERS_DIR" <<'SCRIPT_EOF'
f="$1"; udir="$2"
if [ -r "$f" ]; then
  awk -F': *' 'NF >= 2 && $1 != "" {
    gsub(/[[:space:]]+$/, "", $2)
    if ($2 != "" && $2 != "nobody" && $2 != "root") print $1 " " $2
  }' "$f" | sort -u
elif [ -d "$udir" ]; then
  for uf in "$udir"/*; do
    [ -f "$uf" ] || continue
    u=$(basename "$uf")
    case "$u" in root|nobody|system) continue ;; esac
    d=$(sed -n 's/^DNS=//p' "$uf" | head -1)
    if [ -n "$d" ]; then echo "$d $u"; fi
  done | sort -u
fi
exit 0
SCRIPT_EOF
}

# Identifies what a document root runs. Checks exactly what the migration's
# own config parsers read (see discover_app_db_credentials), so the audit
# never promises support the pipeline does not have.
detect_platform() {
  remote_script source "$1" <<'SCRIPT_EOF'
w="$1"
if [ -f "$w/wp-config.php" ]; then
  echo WordPress
elif [ -f "$w/../artisan" ] || [ -f "$w/artisan" ]; then
  echo Laravel
elif [ -f "$w/configuration.php" ] && grep -q 'JConfig' "$w/configuration.php" 2>/dev/null; then
  echo Joomla
elif [ -n "$(find "$w/" -maxdepth 1 -name '*.php' -type f 2>/dev/null | head -1)" ]; then
  echo PHP
elif [ -f "$w/index.html" ] || [ -f "$w/index.htm" ]; then
  echo static
else
  echo unknown
fi
exit 0
SCRIPT_EOF
}

# Real mailbox addresses for an account. The '@' filter matters: the listing
# also contains bare usernames (catch-all destinations) that are not mailboxes.
detect_mailboxes() {
  c_ssh source "uapi --user=$(printf '%q' "$1") Email list_pops 2>/dev/null" \
    | sed -n 's/^[[:space:]]*email:[[:space:]]*//p' | grep '@' || true
}

# The domain's catch-all destination as cPanel stores it, or nothing.
detect_catchall() {
  remote_script source "$SRC_VALIASES_DIR" "$1" <<'SCRIPT_EOF'
f="$1/$2"
[ -r "$f" ] || exit 0
sed -n 's/^\*:[[:space:]]*//p' "$f" | head -1
exit 0
SCRIPT_EOF
}

# cPanel's default catch-all is a reject/blackhole, not a real address.
# Prints "none" for those and "forward:<destination>" for a real one.
classify_catchall() {
  case "${1:-}" in
    ""|:fail:*|:blackhole:*) echo "none" ;;
    *) echo "forward:$1" ;;
  esac
}

# Addon and parked domains owned by an account. The automated pipeline only
# migrates the account's main domain, so the operator must know about these.
source_extra_domains() {
  remote_script source "$SRC_USERDATADOMAINS_FILE" "$1" <<'SCRIPT_EOF'
f="$1"; u="$2"
[ -r "$f" ] || exit 0
awk -v u="$u" -F'==' '{
  split($1, a, ": ")
  if (a[2] == u && ($3 == "addon" || $3 == "parked")) printf "%s ", a[1]
}' "$f"
exit 0
SCRIPT_EOF
}

source_php_versions() {
  c_ssh source "uapi --user=$(printf '%q' "$1") LangPHP php_get_vhost_versions 2>/dev/null" \
    | sed -n 's/^[[:space:]]*version:[[:space:]]*//p' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# Distinct real character sets across a database's tables — per-table
# collation, deliberately NOT the schema default (see TROUBLESHOOTING.md).
source_db_charsets() {
  local db="$1"
  [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || return 0
  c_ssh source "mysql -N -B -e \"SELECT DISTINCT c.character_set_name FROM information_schema.tables t JOIN information_schema.collation_character_set_applicability c ON c.collation_name = t.table_collation WHERE t.table_schema='${db}' AND t.table_type='BASE TABLE';\" 2>/dev/null" \
    | tr '\n' ' ' | sed 's/ *$//'
}

source_db_exists() {
  local db="$1"
  [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  [[ -n "$(c_ssh source "mysql -N -B -e \"SHOW DATABASES LIKE '${db}';\" 2>/dev/null" | tr -d '[:space:]')" ]]
}

source_db_size_kb() {
  local db="$1" kb
  [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || { echo 0; return 0; }
  kb=$(c_ssh source "mysql -N -B -e \"SELECT COALESCE(ROUND(SUM(data_length+index_length)/1024),0) FROM information_schema.tables WHERE table_schema='${db}';\" 2>/dev/null" | tr -d '[:space:]')
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  echo "$kb"
}

source_account_kb() {
  local kb
  kb=$(c_ssh source "du -sk /home/$(printf '%q' "$1") 2>/dev/null | cut -f1" | tr -d '[:space:]')
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  echo "$kb"
}

# ---------------------------------------------------------------------------
# The audit
# ---------------------------------------------------------------------------

audit_source_accounts() {
  local pairs="${ACCOUNT_LIST:-}"
  if [[ -z "$pairs" ]]; then
    pairs=$(source_account_pairs)
  fi
  if [[ -z "$pairs" ]]; then
    err "No accounts found on the source server."
    return 1
  fi

  local total
  total=$(printf '%s\n' "$pairs" | grep -c '[^[:space:]]' || true)
  log "Scanning ${total} account(s). Sizing large home directories can take a while."

  local tsv="${AUDIT_DIR:-/tmp}/source-accounts.tsv"
  printf 'domain\tuser\tplatform\tdatabase\tdb_user\tcharset\tmailboxes\tcatchall\tdisk_kb\n' > "$tsv"
  chmod 600 "$tsv" 2>/dev/null || true

  SOURCE_ACCOUNT_COUNT=0
  SOURCE_TOTAL_KB=0
  SOURCE_DB_KB=0

  local n=0 domain user
  local webroot realroot is_link platform creds db dbuser charset mail_count catchall_raw catchall
  local extra kb dbkb phpv
  # A here-string, not a pipe: counters set in the loop must survive it.
  while read -r domain user; do
    [[ -z "$domain" || -z "$user" ]] && continue
    n=$((n + 1))

    if ! [[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$user" =~ ^[A-Za-z0-9_-]+$ ]]; then
      warn "[${n}/${total}] Skipping '${domain} ${user}' — unexpected characters in the name."
      continue
    fi

    log "[${n}/${total}] ${domain}  (cPanel user: ${user})"

    webroot="/home/${user}/public_html"
    is_link=$(c_ssh source "test -L $(printf '%q' "$webroot") && echo yes || echo no" | tr -d '[:space:]')
    realroot=$(c_ssh source "readlink -f $(printf '%q' "$webroot")" | tr -d '\r')
    [[ -z "$realroot" ]] && realroot="$webroot"

    platform=$(detect_platform "$realroot")

    # Name and user only. The password field is discarded on purpose.
    creds=$(discover_app_db_credentials "$user" "$realroot")
    db=$(printf '%s' "$creds" | cut -f1)
    dbuser=$(printf '%s' "$creds" | cut -f2)
    creds=""
    charset=""
    dbkb=0
    if [[ -n "$db" ]]; then
      if source_db_exists "$db"; then
        charset=$(source_db_charsets "$db")
        dbkb=$(source_db_size_kb "$db")
      else
        warn "      The app references database '${db}' but it does not exist on the source."
        warn "      The migration will skip it rather than invent an empty one."
      fi
    fi

    mail_count=$(detect_mailboxes "$user" | grep -c '@' || true)
    catchall_raw=$(detect_catchall "$domain")
    catchall=$(classify_catchall "$catchall_raw")

    kb=$(source_account_kb "$user")
    phpv=$(source_php_versions "$user")

    log "      platform: ${platform}   PHP: ${phpv:-unknown}   size: $((kb / 1024)) MB"
    log "      database: ${db:-none found}${dbuser:+ (user ${dbuser})}${charset:+   charset: ${charset}}"
    log "      mailboxes: ${mail_count}   catch-all: ${catchall}"

    if [[ "$is_link" == "yes" ]]; then
      log "      public_html is a symlink -> ${realroot} (the whole project root will be transferred)"
    fi

    extra=$(source_extra_domains "$user")
    if [[ -n "${extra// /}" ]]; then
      warn "      Addon/parked domains on this account: ${extra}"
      warn "      The automated pipeline migrates the MAIN domain only — these need a separate run."
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$domain" "$user" "$platform" "$db" "$dbuser" "$charset" "$mail_count" "$catchall" "$kb" >> "$tsv"

    SOURCE_ACCOUNT_COUNT=$((SOURCE_ACCOUNT_COUNT + 1))
    SOURCE_TOTAL_KB=$((SOURCE_TOTAL_KB + kb))
    SOURCE_DB_KB=$((SOURCE_DB_KB + dbkb))
  done <<< "$pairs"

  export SOURCE_ACCOUNT_COUNT SOURCE_TOTAL_KB SOURCE_DB_KB
  return 0
}

audit_source_full() {
  section "Source audit — ${SOURCE_HOST:-?}"
  local rc=0

  local is_cpanel
  is_cpanel=$(c_ssh source "test -d /usr/local/cpanel -o -d /var/cpanel && echo yes || echo no" | tr -d '[:space:]')
  if [[ "$is_cpanel" == "yes" ]]; then
    ok "cPanel/WHM detected."
  else
    warn "This does not look like a cPanel server (no /usr/local/cpanel or /var/cpanel)."
    warn "Discovery below assumes cPanel — see docs/SUPPORTED-SCENARIOS.md."
  fi

  local missing
  missing=$(remote_missing_tools source rsync tar mysql mysqldump)
  if [[ -n "${missing// /}" ]]; then
    err "Missing on the source: ${missing}— the transfer and database steps need these."
    rc=1
  else
    ok "rsync, tar, mysql and mysqldump are present on the source."
  fi
  missing=$(remote_missing_tools source uapi)
  if [[ -n "${missing// /}" ]]; then
    warn "'uapi' is not available on the source — mailbox discovery will find nothing."
  fi

  local stack
  stack=$(detect_security_stack source)
  if [[ -n "$stack" ]]; then
    log "Security layers detected on the source: ${stack}"
    if [[ "$stack" == *CSF* || "$stack" == *Imunify360* || "$stack" == *cPHulk* || "$stack" == *fail2ban* ]]; then
      warn "These can rate-limit or ban the machine running this wizard mid-transfer."
      warn "Whitelist this machine's public IP on the source before continuing."
    fi
  else
    log "No host-security layers detected on the source."
  fi

  # Inventory of the source's PHP limits, consumed later by check_php_parity /
  # fix_php_parity on the target. Read from the php CLI: per-domain MultiPHP
  # overrides are not visible here.
  local limits envf="${AUDIT_DIR:-/tmp}/source-php-limits.env"
  limits=$(php_limits_of source)
  if [[ -n "$limits" ]]; then
    printf '%s\n' "$limits" > "$envf"
    log "Source PHP limits (php CLI): $(printf '%s' "$limits" | tr '\n' ' ')"
  else
    warn "Could not read PHP limits from the source; the PHP parity check will be skipped."
    : > "$envf"
  fi

  if ! audit_source_accounts; then
    rc=1
  else
    section "Source summary"
    log "Accounts: ${SOURCE_ACCOUNT_COUNT}   Files+mail: $((SOURCE_TOTAL_KB / 1024)) MB   Databases: $((SOURCE_DB_KB / 1024)) MB"
    log "Per-account details: ${AUDIT_DIR:-/tmp}/source-accounts.tsv"
  fi

  log "Nothing was changed on the source server."
  return "$rc"
}
