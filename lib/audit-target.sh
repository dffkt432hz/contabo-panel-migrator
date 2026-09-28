#!/usr/bin/env bash
# audit-target.sh — Step 7b: is the target server actually ready?
#
# Read-only, with ONE exception: fix_php_parity changes PHP configuration on
# the target, and only when the operator confirms it (in the wizard) or runs
# it by hand (as the sanity check suggests).
#
# audit_target_full sets TARGET_PANEL (virtualmin | webmin | cpanel | none)
# and returns non-zero when an automated migration must not proceed:
#   * no Webmin/Virtualmin at all, or a cPanel target
#   * required tools missing
#   * not enough disk for the source's real footprint
#
# It reads SOURCE_TOTAL_KB / SOURCE_DB_KB (set by audit_source_full) and the
# source PHP limits file the source audit wrote.

# Where fix_php_parity drops its ini file. Space-separated glob patterns, one
# per PHP layout: Debian/Ubuntu per-SAPI trees, RHEL-family /etc/php.d, and
# Remi software-collection trees. Overridable so the offline tests can aim
# the fix at a temp directory instead of the real /etc.
TARGET_PHP_INI_DIRS="${TARGET_PHP_INI_DIRS:-/etc/php/*/cli/conf.d /etc/php/*/fpm/conf.d /etc/php/*/apache2/conf.d /etc/php.d /etc/opt/remi/php*/php.d}"
TARGET_PHP_INI_NAME="99-panel-migrator-limits.ini"
# PHP-FPM pool files, checked for per-pool values that would override a
# php.ini drop-in.
TARGET_FPM_POOL_DIRS="${TARGET_FPM_POOL_DIRS:-/etc/php-fpm.d /etc/php/*/fpm/pool.d /etc/opt/remi/php*/php-fpm.d}"

# ---------------------------------------------------------------------------
# Panel detection
# ---------------------------------------------------------------------------
_target_panel_probe() {
  remote_script target <<'SCRIPT_EOF'
if command -v virtualmin >/dev/null 2>&1 \
   && { virtualmin list-commands >/dev/null 2>&1 </dev/null || virtualmin list-domains --name-only >/dev/null 2>&1 </dev/null; }; then
  echo virtualmin
elif [ -d /usr/local/cpanel ]; then
  echo cpanel
elif [ -f /etc/webmin/miniserv.conf ]; then
  echo webmin
else
  echo none
fi
exit 0
SCRIPT_EOF
}

detect_target_panel() {
  TARGET_PANEL=$(_target_panel_probe | tr -d '[:space:]')
  [[ -z "$TARGET_PANEL" ]] && TARGET_PANEL="none"
  export TARGET_PANEL
}

# ---------------------------------------------------------------------------
# PHP parity
# ---------------------------------------------------------------------------

# Warns about per-pool PHP-FPM settings: those override php.ini, so a
# drop-in alone would silently not take effect for the affected pools.
_target_fpm_pool_overrides() {
  remote_script target "$TARGET_FPM_POOL_DIRS" <<'SCRIPT_EOF'
for pat in $1; do
  for d in $pat; do
    [ -d "$d" ] || continue
    grep -lE '^[[:space:]]*php(_admin)?_(value|flag)\[(memory_limit|upload_max_filesize|post_max_size|max_execution_time|max_input_vars)\]' "$d"/*.conf 2>/dev/null
  done
done
exit 0
SCRIPT_EOF
}

# Compares the source's recorded PHP limits with the target's. Returns 0 on
# parity (target >= source for every key), 1 when at least one key is lower
# on the target. A LOWER source value is never a problem, so it is ignored.
check_php_parity() {
  local envf="${AUDIT_DIR:-/tmp}/source-php-limits.env"
  if [[ ! -s "$envf" ]]; then
    log "No source PHP limits were recorded — skipping the PHP parity check."
    return 0
  fi

  local tgt key want have wn hn gaps=0
  tgt=$(php_limits_of target)
  if [[ -z "$tgt" ]]; then
    warn "Could not read PHP limits from the target (is the php CLI installed?)."
    return 1
  fi

  while IFS='=' read -r key want; do
    [[ -z "$key" || -z "$want" ]] && continue
    have=$(printf '%s\n' "$tgt" | sed -n "s/^${key}=//p" | head -1)
    wn=$(ini_to_num "$want" "$key")
    hn=$(ini_to_num "$have" "$key")
    [[ -z "$wn" ]] && continue
    if [[ -z "$hn" || "$wn" -gt "$hn" ]]; then
      warn "PHP ${key}: source=${want}  target=${have:-unset}"
      gaps=$((gaps + 1))
    fi
  done < "$envf"

  if [[ "$gaps" -eq 0 ]]; then
    ok "Target PHP limits meet or exceed the source's."
    return 0
  fi

  local overrides
  overrides=$(_target_fpm_pool_overrides)
  if [[ -n "$overrides" ]]; then
    warn "These PHP-FPM pool files set their own values, which override php.ini:"
    printf '%s\n' "$overrides" | sed 's/^/        /' >&2
    warn "A php.ini drop-in will not change those pools — edit the pool files too."
  fi
  return 1
}

# Raises the target's PHP limits to the source's, never lowering anything.
# Writes ONE drop-in file (never edits the distro's php.ini, so package
# upgrades cannot undo it), backs up any previous copy, reloads php-fpm,
# then re-reads the effective values to confirm they took.
fix_php_parity() {
  local envf="${AUDIT_DIR:-/tmp}/source-php-limits.env"
  if [[ ! -s "$envf" ]]; then
    err "No source PHP limits recorded — run the source audit first."
    return 1
  fi

  local tgt body="" key want have wn hn
  tgt=$(php_limits_of target)
  while IFS='=' read -r key want; do
    [[ -z "$key" || -z "$want" ]] && continue
    have=$(printf '%s\n' "$tgt" | sed -n "s/^${key}=//p" | head -1)
    wn=$(ini_to_num "$want" "$key")
    hn=$(ini_to_num "$have" "$key")
    [[ -z "$wn" ]] && continue
    if [[ -z "$hn" || "$wn" -gt "$hn" ]]; then
      body+="${key} = ${want}"$'\n'
    fi
  done < "$envf"

  if [[ -z "$body" ]]; then
    ok "Nothing to change — the target already meets the source's PHP limits."
    return 0
  fi

  log "Writing ${TARGET_PHP_INI_NAME} on the target:"
  printf '%s' "$body" | sed 's/^/        /'

  local written
  written=$(_target_write_php_dropin "$body")
  if [[ -z "$written" ]]; then
    err "No PHP configuration directory found on the target (looked in: ${TARGET_PHP_INI_DIRS})."
    err "Set the limits by hand, or export TARGET_PHP_INI_DIRS and re-run."
    return 1
  fi
  printf '%s\n' "$written" | sed 's/^/        wrote /'

  log "Re-reading the effective limits to confirm they took..."
  check_php_parity
}

_target_write_php_dropin() {
  remote_script target "$1" "$TARGET_PHP_INI_DIRS" "$TARGET_PHP_INI_NAME" <<'SCRIPT_EOF'
body="$1"; pats="$2"; name="$3"
wrote=0
for pat in $pats; do
  for d in $pat; do
    [ -d "$d" ] || continue
    if [ -f "$d/$name" ]; then cp -p "$d/$name" "$d/$name.bak.$(date +%s)"; fi
    printf '%s' "$body" > "$d/$name" || continue
    # Read back: never assume a write worked.
    if [ "$(cat "$d/$name")" = "$(printf '%s' "$body")" ]; then
      echo "$d/$name"
      wrote=1
    fi
  done
done
if [ "$wrote" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  for u in $(systemctl list-units --type=service --no-legend 'php*fpm*' 2>/dev/null </dev/null | awk '{print $1}'); do
    systemctl try-restart "$u" >/dev/null 2>&1 </dev/null
  done
fi
exit 0
SCRIPT_EOF
}

# ---------------------------------------------------------------------------
# Quota, services, disk
# ---------------------------------------------------------------------------

# A default plan with a block-quota cap silently truncates large transfers.
# The migration lifts the cap per domain, but a capped default plan is worth
# knowing about up front.
check_default_quota() {
  [[ "${TARGET_PANEL:-}" == "virtualmin" ]] || return 0
  local plans quota
  plans=$(c_ssh target "virtualmin list-plans --multiline 2>/dev/null")
  quota=$(printf '%s\n' "$plans" | vm_field 'Server block quota')
  if [[ -z "$quota" || "$quota" == "Unlimited" ]]; then
    ok "Default account plan has no block-quota cap."
  else
    warn "The first account plan caps block quota at: ${quota}"
    warn "The migration lifts the cap per domain (virtualmin modify-domain --quota UNLIMITED),"
    warn "but new domains inherit this cap until it does. Consider raising it under"
    warn "Virtualmin > System Settings > Account Plans."
  fi
}

_target_inactive_services() {
  remote_script target <<'SCRIPT_EOF'
check_group() {
  for s in "$@"; do
    if systemctl is-active --quiet "$s" 2>/dev/null </dev/null; then return 0; fi
  done
  printf '%s ' "$1"
}
command -v systemctl >/dev/null 2>&1 || exit 0
check_group apache2 httpd
check_group mysql mariadb mysqld
check_group dovecot
check_group postfix
exit 0
SCRIPT_EOF
}

# Prints "<device> <available_kb>" for the filesystem holding a path.
_target_fs_info() {
  c_ssh target "df -Pk $(printf '%q' "$1") 2>/dev/null | awk 'NR==2 {print \$1, \$4}'"
}

# Compares the source's REAL footprint against the target's free space before
# anything is copied. If files and databases share a filesystem their needs
# are added together rather than checked separately.
check_target_disk() {
  local need_files="${SOURCE_TOTAL_KB:-0}" need_db="${SOURCE_DB_KB:-0}"
  if [[ "$need_files" -eq 0 && "$need_db" -eq 0 ]]; then
    log "Source size unknown — skipping the disk-space check."
    return 0
  fi

  local home_info db_info home_dev home_free db_dev db_free
  home_info=$(_target_fs_info /home)
  db_info=$(_target_fs_info /var/lib/mysql)
  [[ -z "$db_info" ]] && db_info=$(_target_fs_info /var)
  home_dev=${home_info%% *}; home_free=${home_info##* }
  db_dev=${db_info%% *};     db_free=${db_info##* }

  # Databases need room for the data plus engine overhead while importing.
  local db_need=$((need_db * 3 / 2))
  local rc=0

  if [[ -n "$home_dev" && "$home_dev" == "$db_dev" ]]; then
    if disk_headroom_ok $((need_files + db_need)) "$home_free"; then
      ok "Disk: $((home_free / 1024)) MB free vs about $(((need_files + db_need) / 1024)) MB needed (files + databases share a filesystem)."
    else
      err "Disk: only $((home_free / 1024)) MB free; files + databases need about $(((need_files + db_need) * 110 / 100 / 1024)) MB with margin."
      rc=1
    fi
  else
    if disk_headroom_ok "$need_files" "${home_free:-0}"; then
      ok "Disk (/home): $((${home_free:-0} / 1024)) MB free vs about $((need_files / 1024)) MB needed."
    else
      err "Disk (/home): only $((${home_free:-0} / 1024)) MB free; the files need about $((need_files / 1024)) MB plus margin."
      rc=1
    fi
    if disk_headroom_ok "$db_need" "${db_free:-0}"; then
      ok "Disk (databases): $((${db_free:-0} / 1024)) MB free vs about $((db_need / 1024)) MB needed."
    else
      err "Disk (databases): only $((${db_free:-0} / 1024)) MB free; imports need about $((db_need / 1024)) MB."
      rc=1
    fi
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# The audit
# ---------------------------------------------------------------------------
audit_target_full() {
  section "Target audit — ${TARGET_HOST:-?}"
  local rc=0

  detect_target_panel
  case "$TARGET_PANEL" in
    virtualmin)
      ok "Webmin + Virtualmin detected on the target."
      ;;
    webmin)
      warn "Only bare Webmin was found (no virtual-server module)."
      warn "Domain creation, PHP pools and catch-all setup need Virtualmin."
      ;;
    cpanel)
      err "The target is a cPanel server. Use WHM's own Transfer Tools for cPanel -> cPanel."
      return 1
      ;;
    *)
      err "No Webmin or Virtualmin found on the target."
      err "Install Virtualmin first: https://www.virtualmin.com/download/"
      return 1
      ;;
  esac

  local missing
  missing=$(remote_missing_tools target rsync tar mysql openssl curl)
  if [[ -n "${missing// /}" ]]; then
    err "Missing on the target: ${missing}— the transfer and verification steps need these."
    rc=1
  else
    ok "rsync, tar, mysql, openssl and curl are present on the target."
  fi

  local inactive
  inactive=$(_target_inactive_services)
  if [[ -n "${inactive// /}" ]]; then
    warn "Not running on the target: ${inactive}"
    warn "Start them before migrating: systemctl enable --now <service>"
  else
    ok "Web, database, IMAP and SMTP services are running."
  fi

  local stack
  stack=$(detect_security_stack target)
  if [[ -n "$stack" ]]; then
    log "Security layers detected on the target: ${stack}"
    if [[ "$stack" == *CSF* || "$stack" == *fail2ban* || "$stack" == *Imunify360* ]]; then
      warn "Whitelist the machine running this wizard on the target too, or a long"
      warn "transfer can get it banned partway through."
    fi
  else
    log "No host-security layers detected on the target."
  fi

  check_default_quota

  if ! check_php_parity; then
    warn "The target's PHP limits are lower than the source's. Heavy sites can 500 with"
    warn "nothing in the error log when they hit the new, lower limit."
    if confirm "Raise the target's PHP limits to match the source now? (restarts php-fpm briefly)"; then
      fix_php_parity || warn "PHP parity is not fully resolved — see above."
    else
      log "Skipped. Run it later with: fix_php_parity"
    fi
  fi

  check_target_disk || rc=1

  if [[ "$rc" -ne 0 ]]; then
    err "The target is NOT ready for an automated migration."
  else
    ok "Target audit passed."
  fi
  return "$rc"
}
