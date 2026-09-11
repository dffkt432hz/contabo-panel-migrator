#!/usr/bin/env bash
# migrate-account.sh — Step 3: move one account, in the order that actually
# works.
#
# The order is not arbitrary and is the single most common thing to get
# wrong:
#   * Domain creation must come BEFORE the file transfer, because
#     create-domain is what creates public_html in the first place — an
#     rsync into a directory that doesn't exist yet fails with a confusing
#     mkdir error from inside rsync.
#   * Certificate issuance must come AFTER DNS cutover, because Let's
#     Encrypt's HTTP-01 validator resolves the domain for real and connects
#     to whatever IP it currently, publicly points at.
#
# Each phase is separately callable, so a failed run resumes from the step
# that failed rather than starting over.

migrate_account() {
  local domain="$1" cpanel_user="$2" new_user="${3:-$2}"
  section "Migrating $domain ($cpanel_user -> $new_user)"

  phase_create_domain   "$domain" "$new_user" || { err "Domain creation failed — skipping the rest of this account."; return 1; }
  phase_transfer_files  "$domain" "$cpanel_user" "$new_user"
  phase_migrate_database "$domain" "$cpanel_user" "$new_user"
  phase_deploy_key      "$new_user"
  phase_migrate_mail    "$domain" "$cpanel_user" "$new_user"
  phase_catchall        "$domain" "$new_user"

  ok "$domain: files, database, and mail migrated."
  log "DNS cutover and certificate issuance run separately — certificates"
  log "can only be issued once DNS actually points at the target."
}

# ---------------------------------------------------------------------------
phase_create_domain() {
  local domain="$1" user="$2"
  section "  [1/6] Creating domain on target"

  if c_ssh target "virtualmin list-domains --domain $(printf '%q' "$domain") >/dev/null 2>&1"; then
    ok "  Domain $domain already exists on target — skipping creation."
    return 0
  fi

  local pass
  pass=$(openssl rand -base64 24)

  # Every one of these flags is required together: omitting --unix/--dir
  # produces a "cannot be enabled without an administration user" error
  # even when --web/--webmin are present, and omitting --pass fails with
  # "Missing password" while creating nothing at all.
  if ! c_ssh target "virtualmin create-domain \
      --domain $(printf '%q' "$domain") \
      --user $(printf '%q' "$user") \
      --pass $(printf '%q' "$pass") \
      --unix --dir --web --dns --mail --mysql --ssl --webmin \
      --email $(printf '%q' "admin@${domain}")"; then
    return 1
  fi

  umask 077
  printf '%s\t%s\t%s\n' "$domain" "$user" "$pass" >> "${AUDIT_DIR:-/tmp}/generated-passwords.tsv"
  chmod 600 "${AUDIT_DIR:-/tmp}/generated-passwords.tsv" 2>/dev/null || true
  ok "  Created $domain (owner: $user). Password recorded in ${AUDIT_DIR:-/tmp}/generated-passwords.tsv"
}

# ---------------------------------------------------------------------------
phase_transfer_files() {
  local domain="$1" cpanel_user="$2" new_user="$3"
  section "  [2/6] Transferring files"

  # `public_html` is very often a symlink (Laravel/Symfony deployments
  # point it at <project>/public). Two consequences worth handling before
  # a naive rsync: `find <symlink> -type f` reports zero files and looks
  # like an empty account, and copying only the symlink target silently
  # drops the rest of the project (vendor/, .env, app/ ...).
  local real_root is_symlink
  is_symlink=$(c_ssh source "test -L /home/$(printf '%q' "$cpanel_user")/public_html && echo yes || echo no")
  real_root=$(c_ssh source "readlink -f /home/$(printf '%q' "$cpanel_user")/public_html")

  if [[ "$is_symlink" == "yes" ]]; then
    warn "  public_html on the source is a SYMLINK -> $real_root"
    warn "  Transferring the whole project root instead, then recreating the symlink."
    local project_root
    project_root=$(dirname "$real_root")
    c_relay_tar "$project_root" "/home/${new_user}/$(basename "$project_root")"
    c_ssh target "
      rm -rf /home/$(printf '%q' "$new_user")/public_html
      ln -s /home/$(printf '%q' "$new_user")/$(basename "$project_root")/$(basename "$real_root") /home/$(printf '%q' "$new_user")/public_html
      chown -Rh $(printf '%q' "${new_user}:${new_user}") /home/$(printf '%q' "$new_user")/$(basename "$project_root") /home/$(printf '%q' "$new_user")/public_html
    "
  else
    # Record whether the source genuinely has its own index.html BEFORE
    # transferring, so we can tell a real homepage apart from the
    # placeholder index.html that create-domain drops in. Deleting the
    # wrong one takes a site's homepage offline.
    local source_has_index_html
    source_has_index_html=$(c_ssh source "test -f $(printf '%q' "$real_root")/index.html && echo yes || echo no")

    c_relay_tar "$real_root" "/home/${new_user}/public_html"
    c_ssh target "chown -R $(printf '%q' "${new_user}:${new_user}") /home/$(printf '%q' "$new_user")/public_html"

    if [[ "$source_has_index_html" == "no" ]]; then
      # Safe: the source had no index.html, so anything here is the
      # panel's own placeholder and nothing of the user's is at risk.
      c_ssh target "rm -f /home/$(printf '%q' "$new_user")/public_html/index.html"
      log "  Removed Virtualmin's placeholder index.html (source had none of its own)."
    else
      log "  Source has its own index.html — left in place."
    fi
  fi

  local src_count dst_count
  src_count=$(c_ssh source "find $(printf '%q' "$real_root") -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
  dst_count=$(c_ssh target "find -L /home/$(printf '%q' "$new_user")/public_html -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
  log "  File count — source: ${src_count:-?}, target: ${dst_count:-?}"
  if [[ "${src_count:-0}" -ne "${dst_count:-0}" ]]; then
    warn "  File counts differ. Investigate before treating this account as done."
  fi
}

# ---------------------------------------------------------------------------
# Reads an application's own config file to discover the database name,
# user and password it actually uses. Recreating those values verbatim on
# the target means the app's config file needs ZERO edits after migration,
# which is both less work and one less thing to get wrong.
#
# Echoes three tab-separated fields: name, user, password.
discover_app_db_credentials() {
  local cpanel_user="$1" webroot="$2"
  remote_script source "$webroot" <<'SCRIPT_EOF'
webroot="$1"

emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# --- WordPress ---
wpc="$webroot/wp-config.php"
if [ -f "$wpc" ]; then
  # The closing delimiter is matched with a BACKREFERENCE to the opening
  # one, and the value is captured greedily up to it. A naive [^'"]* class
  # truncates any password containing the other quote character — and a
  # truncated password produces a user that exists but cannot authenticate,
  # which surfaces as a confusing "access denied" long after migration.
  get_wp() {
    sed -n "s/.*define([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*\\(['\"]\\)\\(.*\\)\\1[[:space:]]*)[[:space:]]*;.*/\\2/p" "$wpc" | head -1
  }
  emit "$(get_wp DB_NAME)" "$(get_wp DB_USER)" "$(get_wp DB_PASSWORD)"
  exit 0
fi

# --- Laravel / anything using a .env ---
for envf in "$webroot/../.env" "$webroot/.env"; do
  if [ -f "$envf" ]; then
    get_env() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$envf" | head -1 | sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'; }
    emit "$(get_env DB_DATABASE)" "$(get_env DB_USERNAME)" "$(get_env DB_PASSWORD)"
    exit 0
  fi
done

# --- Joomla ---
jc="$webroot/configuration.php"
if [ -f "$jc" ]; then
  # Same backreferenced-delimiter approach as the WordPress parser above.
  get_j() {
    sed -n "s/.*public \\\$$1[[:space:]]*=[[:space:]]*\\(['\"]\\)\\(.*\\)\\1[[:space:]]*;.*/\\2/p" "$jc" | head -1
  }
  emit "$(get_j db)" "$(get_j user)" "$(get_j password)"
  exit 0
fi

emit "" "" ""
SCRIPT_EOF
}

phase_migrate_database() {
  local domain="$1" cpanel_user="$2" new_user="$3"
  section "  [3/6] Migrating database(s)"

  local webroot="/home/${cpanel_user}/public_html"
  local creds db_name db_user db_pass
  creds=$(discover_app_db_credentials "$cpanel_user" "$webroot")
  db_name=$(printf '%s' "$creds" | cut -f1)
  db_user=$(printf '%s' "$creds" | cut -f2)
  db_pass=$(printf '%s' "$creds" | cut -f3)

  if [[ -n "$db_name" ]]; then
    log "  Found application config: database='${db_name}' user='${db_user}'"
    # Confirm the database the app *claims* to use actually exists. An app
    # can reference a database that was never created (a lazily-used or
    # abandoned feature) — in that case replicate the source's real
    # behaviour rather than helpfully creating an empty database that
    # never existed.
    local exists
    exists=$(c_ssh source "mysql -N -B -e \"SHOW DATABASES LIKE '${db_name}';\" 2>/dev/null" | tr -d '[:space:]')
    if [[ -z "$exists" ]]; then
      warn "  The app references database '${db_name}' but it does not exist on the source."
      warn "  Not creating it on the target either — flagging instead of silently 'fixing' it."
      db_name=""
    fi
  fi

  # Fall back to prefix discovery if the app config gave us nothing.
  local dbs
  if [[ -n "$db_name" ]]; then
    dbs="$db_name"
  else
    dbs=$(c_ssh source "mysql -N -B -e \"SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE '${cpanel_user}%';\" 2>/dev/null")
    [[ -n "$dbs" ]] && warn "  No app config found — falling back to prefix match on '${cpanel_user}%'."
  fi

  if [[ -z "$dbs" ]]; then
    log "  No database for this account, skipping."
    return 0
  fi

  local db
  while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    migrate_one_database "$domain" "$db" "$db_user" "$db_pass"
  done <<< "$dbs"
}

migrate_one_database() {
  local domain="$1" db="$2" db_user="$3" db_pass="$4"

  # Never trust the schema-level default charset: check the REAL per-table
  # collation. A database labelled latin1 whose tables hold clean utf8mb4
  # bytes is common, and dumping it with the wrong charset silently
  # mangles every non-ASCII character with no error at any point.
  local collation charset collate_full
  collation=$(c_ssh source "mysql -N -B -e \"SELECT table_collation FROM information_schema.tables WHERE table_schema='${db}' AND table_type='BASE TABLE' LIMIT 1;\" 2>/dev/null" | tr -d '[:space:]')
  if [[ "$collation" == utf8mb4* ]]; then
    charset="utf8mb4"; collate_full="utf8mb4_unicode_ci"
  else
    charset="latin1"; collate_full="latin1_swedish_ci"
  fi
  log "  Database '${db}': real collation '${collation:-unknown}' -> dumping as ${charset}"

  # Keep the SAME database name on the target. Renaming it would force an
  # edit to every app config file that references it — more work, and a
  # step that is easy to forget on one site out of forty.
  c_ssh target "mysql -e \"CREATE DATABASE IF NOT EXISTS \\\`${db}\\\` CHARACTER SET ${charset} COLLATE ${collate_full};\""

  # Recreate the application's own DB user with its original name and
  # password. Without this the database exists but nothing can connect to
  # it, and every migrated site returns a database connection error.
  if [[ -n "$db_user" ]]; then
    create_db_user "$db" "$db_user" "$db_pass"
  else
    warn "  No application DB user discovered for '${db}'."
    warn "  The database will be imported, but you must create its user manually,"
    warn "  or the site will fail with a database connection error."
  fi

  # Register the database with Virtualmin so it shows up in the panel and
  # is included in the domain's backups. Harmless if it already knows.
  c_ssh target "virtualmin create-database --domain $(printf '%q' "$domain") --name $(printf '%q' "$db") --type mysql 2>/dev/null || true"

  log "  Streaming dump (this can take a while on a large database)..."
  # c_ssh_pipe, NOT c_ssh: c_ssh redirects stdin from /dev/null, which
  # would feed mysql an empty stream and "succeed" while importing nothing.
  if ! c_ssh source "mysqldump --default-character-set=${charset} --single-transaction --quick --routines --triggers $(printf '%q' "$db")" \
     | c_ssh_pipe target "mysql --default-character-set=${charset} $(printf '%q' "$db")"; then
    err "  Import of '${db}' failed. Not continuing with this database."
    return 1
  fi

  local src_rows dst_rows
  src_rows=$(db_total_rows source "$db")
  dst_rows=$(db_total_rows target "$db")
  log "  Row count — source: ${src_rows:-?}, target: ${dst_rows:-?}"
  if [[ "${src_rows:-0}" == "${dst_rows:-0}" ]]; then
    ok "  '${db}' imported and row counts match exactly."
  else
    warn "  Row counts differ for '${db}' — re-run this database before going live."
  fi
}

create_db_user() {
  local db="$1" user="$2" pass="$3"
  # Written as a here-doc'd script rather than an `ssh ... 'mysql -e "..."'`
  # one-liner on purpose: a password containing `$` (or a quote) is silently
  # corrupted by that nested quoting, producing a user that exists but whose
  # password doesn't work, with a misleading auth error at the far end.
  #
  # Both 'localhost' and '127.0.0.1' grants are created: MySQL/MariaDB do
  # not treat them as interchangeable when matching grants, and a Laravel
  # .env with DB_HOST=127.0.0.1 will fail against a localhost-only grant.
  local rc=0
  remote_script target "$db" "$user" "$pass" <<'SCRIPT_EOF' || rc=$?
db="$1"; user="$2"; pass="$3"
tmp=$(mktemp)
chmod 600 "$tmp"
{
  printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED BY '%s';\n" "$user" "$pass"
  printf "CREATE USER IF NOT EXISTS '%s'@'127.0.0.1' IDENTIFIED BY '%s';\n" "$user" "$pass"
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'localhost';\n" "$db" "$user"
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'127.0.0.1';\n" "$db" "$user"
  printf "FLUSH PRIVILEGES;\n"
} > "$tmp"
mysql < "$tmp"
rc=$?
rm -f "$tmp"
exit $rc
SCRIPT_EOF
  if [[ $rc -eq 0 ]]; then
    ok "  DB user '${user}' recreated with its original password (no app config edit needed)."
  else
    err "  Failed to create DB user '${user}' — the site will not be able to connect."
    err "  If the target MySQL predates 8.0/10.1, CREATE USER IF NOT EXISTS is"
    err "  unsupported; create the user manually and re-run the sanity check."
  fi
}

# ---------------------------------------------------------------------------
phase_deploy_key() {
  local new_user="$1"
  section "  [4/6] Installing deploy-key SSH access"
  if [[ -z "${DEPLOY_PUBLIC_KEY:-}" ]]; then
    log "  No DEPLOY_PUBLIC_KEY configured, skipping."
    return 0
  fi
  local rc=0
  remote_script target "$new_user" "$DEPLOY_PUBLIC_KEY" <<'SCRIPT_EOF' || rc=$?
user="$1"; key="$2"
id "$user" >/dev/null 2>&1 || { echo "user $user does not exist" >&2; exit 1; }
usermod -s /bin/bash "$user"
mkdir -p "/home/$user/.ssh"
touch "/home/$user/.ssh/authorized_keys"
grep -qxF "$key" "/home/$user/.ssh/authorized_keys" || echo "$key" >> "/home/$user/.ssh/authorized_keys"
chown -R "$user:$user" "/home/$user/.ssh"
chmod 700 "/home/$user/.ssh"
chmod 600 "/home/$user/.ssh/authorized_keys"
SCRIPT_EOF
  if [[ $rc -eq 0 ]]; then
    ok "  Deploy key installed for ${new_user}."
  else
    warn "  Deploy key install failed for ${new_user} (does the Unix user exist yet?)."
  fi
}

# ---------------------------------------------------------------------------
phase_migrate_mail() {
  local domain="$1" cpanel_user="$2" new_user="$3"
  section "  [5/6] Migrating mailboxes"

  # Require an `@` in the match: a source panel's mailbox listing also
  # contains bare usernames (catch-all destinations), which are not real
  # addresses and must not be treated as mailboxes to recreate.
  local boxes
  boxes=$(c_ssh source "uapi --user=$(printf '%q' "$cpanel_user") Email list_pops 2>/dev/null" \
          | sed -n 's/^[[:space:]]*email:[[:space:]]*//p' | grep '@' || true)

  if [[ -z "$boxes" ]]; then
    log "  No real mailboxes found for this account, skipping."
    return 0
  fi

  local fulladdr
  while IFS= read -r fulladdr; do
    [[ -z "$fulladdr" ]] && continue
    migrate_one_mailbox "$domain" "$cpanel_user" "$new_user" "$fulladdr"
  done <<< "$boxes"
}

migrate_one_mailbox() {
  local domain="$1" cpanel_user="$2" new_user="$3" fulladdr="$4"
  local mailuser="${fulladdr%@*}"
  local maildomain="${fulladdr#*@}"
  log "  Mailbox: $fulladdr"

  # Only the password *hash* is ever available (never plaintext), which is
  # also why IMAP-level tools like imapsync are not an option here.
  local hash
  hash=$(c_ssh source "grep '^${mailuser}:' /home/$(printf '%q' "$cpanel_user")/etc/$(printf '%q' "$maildomain")/shadow 2>/dev/null | cut -d: -f2")
  if [[ -z "$hash" ]]; then
    warn "    No password hash on the source for ${fulladdr} — skipping this mailbox."
    warn "    (Check the local part: source panels sometimes store a longer name"
    warn "     than the one shown in a summary listing, e.g. 'first.last' vs 'first'.)"
    return 1
  fi

  if ! c_ssh target "virtualmin list-users --domain $(printf '%q' "$domain") --user $(printf '%q' "$mailuser") >/dev/null 2>&1"; then
    c_ssh target "virtualmin create-user --domain $(printf '%q' "$domain") --user $(printf '%q' "$mailuser") --encpass $(printf '%q' "$hash")" \
      || warn "    create-user failed for ${fulladdr} (a conflicting mail alias with the same name is the usual cause)."
  else
    log "    Mailbox account already exists on target."
  fi

  # Quotas must be lifted BEFORE the transfer. A default quota truncates a
  # large Maildir mid-write with no error at transfer time — it surfaces
  # much later as a message-count shortfall or a failed reindex.
  c_ssh target "virtualmin modify-domain --domain $(printf '%q' "$domain") --quota UNLIMITED --uquota UNLIMITED >/dev/null 2>&1 || true"
  c_ssh target "virtualmin modify-user --domain $(printf '%q' "$domain") --user $(printf '%q' "$mailuser") --quota UNLIMITED >/dev/null 2>&1 || true"

  local src_maildir="/home/${cpanel_user}/mail/${maildomain}/${mailuser}"
  local dst_maildir="/home/${new_user}/homes/${mailuser}/Maildir"

  if ! c_ssh source "test -d $(printf '%q' "$src_maildir")"; then
    warn "    No Maildir at ${src_maildir} — account created, but no message content to move."
    return 0
  fi

  # Dovecot's own index/cache files are excluded and rebuilt clean on the
  # target. Mixing old and new index state is the real corruption risk
  # here — the message files themselves are safe to copy verbatim.
  c_relay_tar "$src_maildir" "$dst_maildir" "--exclude=dovecot*"

  # Each mailbox has its OWN system UID, distinct from the domain owner's,
  # sharing only the domain's GID. A blanket chown to the domain owner
  # breaks every mailbox under it: Dovecot cannot write its indexes, and
  # reports a bogus messages=0 that looks exactly like an empty mailbox.
  remote_script target "$fulladdr" "$new_user" "$dst_maildir" <<'SCRIPT_EOF'
addr="$1"; owner="$2"; maildir="$3"
muid=$(id -u "$addr" 2>/dev/null)
dgid=$(id -g "$owner" 2>/dev/null)
if [ -n "$muid" ] && [ -n "$dgid" ]; then
  chown -R "$muid:$dgid" "$(dirname "$maildir")"
else
  echo "could not resolve uid/gid for $addr / $owner" >&2
  exit 1
fi
doveadm index -u "$addr" '*' >/dev/null 2>&1 || true
SCRIPT_EOF

  local src_cnt dst_cnt
  src_cnt=$(c_ssh source "find $(printf '%q' "$src_maildir") -type f \( -path '*/cur/*' -o -path '*/new/*' \) 2>/dev/null | wc -l" | tr -d '[:space:]')
  dst_cnt=$(c_ssh target "find $(printf '%q' "$dst_maildir") -type f \( -path '*/cur/*' -o -path '*/new/*' \) 2>/dev/null | wc -l" | tr -d '[:space:]')
  log "    Messages — source: ${src_cnt:-?}, target: ${dst_cnt:-?}"
  if [[ "${dst_cnt:-0}" -lt "${src_cnt:-0}" ]]; then
    warn "    Target has FEWER messages than source. Re-transfer this mailbox in full —"
    warn "    do not attempt a delta, and check the domain's mail quota first."
  else
    ok "    Message content verified (target >= source is normal on a live mailbox)."
  fi
}

# ---------------------------------------------------------------------------
# Enables a domain-wide catch-all, matching what cPanel provides per account
# by default and what people therefore silently lose in a migration.
#
# Virtualmin's own `create-alias --from "*"` is broken on at least one real
# build: its valid_alias_name() validator rejects the literal `*` before the
# catch-all code path is ever reached, even though the CLI's own --help
# documents `--from "*"` as the supported way to do this. This calls the
# same internal function the Virtualmin GUI uses instead.
phase_catchall() {
  local domain="$1" new_user="$2"
  section "  [6/6] Setting up catch-all address"
  if [[ "${TARGET_PANEL:-}" != "virtualmin" ]]; then
    log "  Catch-all automation requires a Virtualmin target — skipping."
    return 0
  fi

  ensure_catchall_helper_installed || { warn "  Could not install the catch-all helper, skipping."; return 1; }

  c_ssh target "virtualmin create-user --domain $(printf '%q' "$domain") --user catchall --random-pass --quota UNLIMITED >/dev/null 2>&1 || true"
  if c_ssh target "perl /root/.panel-migrator-set-catchall.pl $(printf '%q' "$domain") $(printf '%q' "catchall@${domain}")"; then
    ok "  catchall@${domain} is now the domain's catch-all address."
  else
    warn "  Catch-all setup failed for ${domain} — check that the virtual-server module path is standard."
  fi
}

ensure_catchall_helper_installed() {
  c_ssh target "test -f /root/.panel-migrator-set-catchall.pl" && return 0
  remote_script target <<'SCRIPT_EOF'
cat > /root/.panel-migrator-set-catchall.pl <<'PERL_EOF'
package virtual_server;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";

# The virtual-server module lives in different places across distributions
# and Webmin packaging, so locate it rather than assuming one path.
my $moddir;
foreach my $candidate ("/usr/libexec/webmin/virtual-server",
                       "/usr/share/webmin/virtual-server",
                       "/opt/webmin/virtual-server") {
    if (-d $candidate) { $moddir = $candidate; last; }
}
die "virtual-server module directory not found\n" unless ($moddir);
chdir($moddir) or die "cannot chdir to $moddir: $!\n";
$0 = "$moddir/set_catchall.pl";
require './virtual-server-lib.pl';
$< == 0 || die "must be run as root\n";
&licence_status();

my $domain = $ARGV[0];
my $fwdto  = $ARGV[1];
die "usage: set_catchall.pl <domain> <forward-to-address>\n" unless ($domain && $fwdto);

my $d = &get_domain_by("dom", $domain);
die "domain not found: $domain\n" unless ($d);

&obtain_lock_mail($d);
&create_domain_forward($d, $fwdto);
&release_lock_mail($d);
&run_post_actions_silently();
print "catchall set for $domain -> $fwdto\n";
PERL_EOF
chmod 700 /root/.panel-migrator-set-catchall.pl
SCRIPT_EOF
}
