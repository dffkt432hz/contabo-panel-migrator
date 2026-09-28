#!/usr/bin/env bash
# sanity-check.sh — Step 4: post-migration verification, where every
# failure prints the exact command that fixes it.
#
# The point of this file is that "the migration script didn't print an
# error" is not evidence that anything worked. Every check here compares a
# real measurement on one server against a real measurement on the other,
# or against a known-good expectation.
#
# Counters are module-level and the loops that touch them deliberately
# avoid pipes: a `while read` on the right-hand side of a pipe runs in a
# subshell, so anything it counts is discarded the moment the loop ends.

SANITY_ISSUES=0
SANITY_CHECKS=0
SANITY_FINDINGS=""

_report() {
  local status="$1" msg="$2" fix="${3:-}"
  SANITY_CHECKS=$((SANITY_CHECKS + 1))
  case "$status" in
    PASS)
      ok "  [PASS] $msg"
      ;;
    WARN|FAIL)
      if [[ "$status" == "WARN" ]]; then warn "  [WARN] $msg"; else err "  [FAIL] $msg"; fi
      if [[ -n "$fix" ]]; then
        printf '         %bfix:%b %s\n' "$C_BOLD" "$C_RESET" "$fix" >&2
      fi
      SANITY_ISSUES=$((SANITY_ISSUES + 1))
      SANITY_FINDINGS+="[${status}] ${msg}"$'\n'
      [[ -n "$fix" ]] && SANITY_FINDINGS+="       fix: ${fix}"$'\n'
      ;;
  esac
}

sanity_check_domain() {
  local domain="$1" cpanel_user="$2" new_user="$3"
  section "Sanity check: $domain"
  SANITY_FINDINGS+="=== ${domain} ==="$'\n'

  check_file_count_match     "$domain" "$cpanel_user" "$new_user"
  check_database_connectivity "$domain" "$cpanel_user" "$new_user"
  check_http_response        "$domain"
  check_cert_validity        "$domain"
  check_php_limits_effective "$new_user"
  check_quota_headroom       "$domain"
  check_mail_setup           "$domain" "$new_user"
}

check_file_count_match() {
  local domain="$1" cpanel_user="$2" new_user="$3"
  local src dst
  src=$(c_ssh source "find -L /home/$(printf '%q' "$cpanel_user")/public_html -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
  dst=$(c_ssh target "find -L /home/$(printf '%q' "$new_user")/public_html -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
  if [[ "${src:-0}" -eq "${dst:-0}" ]]; then
    _report PASS "file count matches (${dst} files)"
  else
    _report WARN "file count mismatch (source=${src} target=${dst})" \
      "re-run: phase_transfer_files '${domain}' '${cpanel_user}' '${new_user}'  — then diff the two directory listings to see what's missing"
  fi
}

# The single most impactful post-migration check: a site whose files and
# database both transferred perfectly still shows a database connection
# error if its DB *user* was never recreated on the target.
check_database_connectivity() {
  local domain="$1" cpanel_user="$2" new_user="$3"

  # discover_app_db_credentials lives in migrate-account.sh. Guarded so
  # this file still works if it's sourced on its own for a spot check.
  if ! declare -f discover_app_db_credentials >/dev/null 2>&1; then
    log "  [skip] database check needs lib/migrate-account.sh to be sourced too"
    return 0
  fi

  local creds db_name db_user db_pass
  creds=$(discover_app_db_credentials "$cpanel_user" "/home/${cpanel_user}/public_html" 2>/dev/null)
  db_name=$(printf '%s' "$creds" | cut -f1)
  db_user=$(printf '%s' "$creds" | cut -f2)
  db_pass=$(printf '%s' "$creds" | cut -f3)

  if [[ -z "$db_name" ]]; then
    log "  [skip] no application database config found for ${domain}"
    return 0
  fi

  local exists
  exists=$(c_ssh target "mysql -N -B -e \"SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_name}';\" 2>/dev/null" | tr -d '[:space:]')
  if [[ -z "$exists" ]]; then
    _report FAIL "database '${db_name}' does not exist on the target" \
      "re-run: phase_migrate_database '${domain}' '${cpanel_user}' '${new_user}'"
    return 1
  fi

  if [[ -z "$db_user" ]]; then
    _report WARN "database '${db_name}' exists but no app DB user was discovered" \
      "check the app's config file and create its user manually on the target"
    return 1
  fi

  # Actually attempt a real connection as the application's own user, with
  # the application's own password. Anything less doesn't prove the site
  # will work.
  local can_connect
  # The credentials travel as the first line of the script on STDIN and the
  # password reaches mysql through MYSQL_PWD, so it is never part of any
  # process argument list (and an empty password cannot trigger a prompt).
  can_connect=$(_db_connect_probe_script | { printf 'user=%q; pass=%q; db=%q\n' "$db_user" "$db_pass" "$db_name"; cat; } | c_ssh_pipe target "bash -s")
  case "$can_connect" in
    yes)
      _report PASS "app can connect to '${db_name}' as '${db_user}'"
      ;;
    localhost-only)
      _report WARN "'${db_user}' can connect via localhost but not 127.0.0.1" \
        "mysql -e \"CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '<password>'; GRANT ALL ON \\\`${db_name}\\\`.* TO '${db_user}'@'127.0.0.1'; FLUSH PRIVILEGES;\"  — needed for any app whose config uses DB_HOST=127.0.0.1"
      ;;
    *)
      _report FAIL "app CANNOT connect to '${db_name}' as '${db_user}' — this site will show a database error" \
        "re-run: create_db_user '${db_name}' '${db_user}' '<password from the app config>'"
      ;;
  esac
}

# The body of the connection probe run on the target. The credentials are
# prepended by the caller as shell variables; MYSQL_PWD carries the password.
_db_connect_probe_script() {
  cat <<'SCRIPT_EOF'
export MYSQL_PWD="$pass"
if mysql -u"$user" -h 127.0.0.1 -N -B -e "USE \`$db\`; SELECT 1;" >/dev/null 2>&1 </dev/null; then
  echo yes
elif mysql -u"$user" -h localhost -N -B -e "USE \`$db\`; SELECT 1;" >/dev/null 2>&1 </dev/null; then
  echo localhost-only
else
  echo no
fi
SCRIPT_EOF
}

check_http_response() {
  local domain="$1"
  local http_code https_code
  https_code=$(c_ssh target "curl -sko /dev/null -w '%{http_code}' --resolve $(printf '%q' "${domain}:443:127.0.0.1") https://$(printf '%q' "$domain")/ 2>/dev/null" | tr -d '[:space:]')
  http_code=$(c_ssh target "curl -so /dev/null -w '%{http_code}' --resolve $(printf '%q' "${domain}:80:127.0.0.1") http://$(printf '%q' "$domain")/ 2>/dev/null" | tr -d '[:space:]')

  case "$https_code" in
    200)     _report PASS "HTTPS returns 200" ;;
    301|302)
      # Very common and usually benign: many sites do both HTTP->HTTPS and
      # non-www <-> www at the application level, which a single-hop check
      # misreads as a problem.
      local followed
      followed=$(c_ssh target "curl -skLo /dev/null -w '%{http_code}' --resolve $(printf '%q' "${domain}:443:127.0.0.1") https://$(printf '%q' "$domain")/ 2>/dev/null" | tr -d '[:space:]')
      if [[ "$followed" == "200" ]]; then
        _report PASS "HTTPS redirects then returns 200 (normal www/non-www handling)"
      else
        _report WARN "HTTPS redirect chain ends in ${followed}" "check for a redirect loop between the app's own config and the server redirect"
      fi
      ;;
    500|502|503)
      _report FAIL "HTTPS returns ${https_code}" \
        "check PHP limits first (a too-low memory_limit gives an unlogged 500): run fix_php_parity — then check the app's error log"
      ;;
    *)
      _report WARN "HTTPS returned '${https_code:-no response}'" "check that the vhost exists and the document root points at the right directory"
      ;;
  esac

  if [[ "$http_code" != "301" && "$http_code" != "302" && "$http_code" != "200" ]]; then
    _report WARN "HTTP (port 80) returned '${http_code:-no response}'" \
      "virtualmin create-redirect --domain '${domain}' --path / --redirect 'https://${domain}/' --http --fix-wellknown --code 301"
  fi
}

check_cert_validity() {
  local domain="$1"
  local issuer subject
  issuer=$(c_ssh target "echo | openssl s_client -connect 127.0.0.1:443 -servername $(printf '%q' "$domain") 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null" | sed 's/^issuer=//')
  subject=$(c_ssh target "echo | openssl s_client -connect 127.0.0.1:443 -servername $(printf '%q' "$domain") 2>/dev/null | openssl x509 -noout -subject 2>/dev/null" | sed 's/^subject=//')

  if [[ -z "$issuer" ]]; then
    _report WARN "no certificate readable for ${domain}" \
      "virtualmin generate-acme-cert --domain '${domain}' --host '${domain}' --host 'www.${domain}'   (only AFTER DNS points at this server)"
  elif [[ "$issuer" == "$subject" ]]; then
    _report WARN "${domain} is serving a self-signed certificate" \
      "virtualmin generate-acme-cert --domain '${domain}' --host '${domain}' --host 'www.${domain}'"
  else
    _report PASS "real certificate active (issuer: ${issuer})"
  fi

  # Checks the certificate served on the IMAP port for the mail hostname.
  # A missing mail.<domain> SAN is invisible from the website's point of
  # view and takes every mail client on the domain offline with an
  # "SSL alert 46 / certificate unknown" error.
  local mail_san
  mail_san=$(c_ssh target "echo | openssl s_client -connect 127.0.0.1:993 -servername $(printf '%q' "mail.${domain}") 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null" | grep -c "mail.${domain}" || true)
  if [[ "${mail_san:-0}" -eq 0 ]]; then
    _report WARN "certificate has no 'mail.${domain}' SAN — mail clients using SSL/TLS to that hostname will fail to connect" \
      "virtualmin generate-acme-cert --domain '${domain}' --host '${domain}' --host 'www.${domain}' --host 'mail.${domain}'"
  else
    _report PASS "mail.${domain} SAN present on the mail certificate"
  fi
}

check_php_limits_effective() {
  local new_user="$1"
  local mem want wn hn envf="${AUDIT_DIR:-/tmp}/source-php-limits.env"
  mem=$(c_ssh target "php -r 'echo ini_get(\"memory_limit\");' 2>/dev/null" | tr -d '[:space:]')
  want=""
  [[ -s "$envf" ]] && want=$(sed -n 's/^memory_limit=//p' "$envf" | head -1)

  if [[ -z "$mem" ]]; then
    _report WARN "could not read the effective PHP memory_limit on the target" "confirm the php CLI is installed: ssh target 'php -v'"
  elif [[ -n "$want" ]]; then
    # The source's real value is known, so compare against THAT rather than
    # guessing what a "stock" value looks like.
    wn=$(ini_to_num "$want" memory_limit); hn=$(ini_to_num "$mem" memory_limit)
    if [[ -n "$wn" && -n "$hn" && "$hn" -lt "$wn" ]]; then
      _report WARN "PHP memory_limit is ${mem} on the target but was ${want} on the source — heavy sites will 500 with nothing in the log" \
        "run fix_php_parity  (from lib/audit-target.sh)"
    else
      _report PASS "PHP memory_limit is ${mem} (source: ${want})"
    fi
  elif [[ "$mem" == "128M" || "$mem" == "64M" || "$mem" == "32M" ]]; then
    _report WARN "PHP memory_limit is a stock default (${mem}) and the source's value is unknown — heavy sites may 500 with nothing in the log" \
      "compare with the source's memory_limit, then run fix_php_parity  (from lib/audit-target.sh)"
  else
    _report PASS "PHP memory_limit is ${mem}"
  fi
}

check_quota_headroom() {
  local domain="$1"
  [[ "${TARGET_PANEL:-}" != "virtualmin" ]] && return 0
  local quota
  quota=$(c_ssh target "virtualmin list-domains --domain $(printf '%q' "$domain") --multiline 2>/dev/null" | vm_field "Server quota")
  if [[ -z "$quota" || "$quota" == "Unlimited" ]]; then
    _report PASS "disk quota unlimited"
  else
    _report WARN "disk quota is capped at ${quota}" \
      "virtualmin modify-domain --domain '${domain}' --quota UNLIMITED --uquota UNLIMITED"
  fi
}

check_mail_setup() {
  local domain="$1" new_user="$2"
  local dkim catchall
  dkim=$(c_ssh target "grep -qxF $(printf '%q' "$domain") /etc/dkim-domains.txt 2>/dev/null && echo yes || echo no" | tr -d '[:space:]')
  if [[ "$dkim" == "yes" ]]; then
    _report PASS "DKIM enabled for ${domain}"
  else
    _report WARN "DKIM not enabled for ${domain} — outbound mail is more likely to be spam-filtered" \
      "echo '${domain}' >> /etc/dkim-domains.txt && systemctl restart opendkim   (then publish the matching TXT record)"
  fi

  catchall=$(c_ssh target "grep -c \"^@${domain}[[:space:]]\" /etc/postfix/virtual 2>/dev/null" | tr -d '[:space:]')
  if [[ "${catchall:-0}" -gt 0 ]]; then
    _report PASS "catch-all address configured"
  else
    _report WARN "no catch-all address for ${domain} — mail to unknown addresses will bounce" \
      "run: phase_catchall '${domain}' '${new_user}'"
  fi
}

sanity_report_summary() {
  section "Sanity check summary"
  log "${SANITY_CHECKS} check(s) run across all domains."
  if [[ "$SANITY_ISSUES" -eq 0 ]]; then
    ok "No issues found."
  else
    warn "${SANITY_ISSUES} issue(s) need attention. Each one is listed above with"
    warn "the exact command that fixes it. Re-run the sanity check afterwards to"
    warn "confirm the fix actually took — 'no error' is not the same as 'fixed'."
    if [[ -n "${AUDIT_DIR:-}" ]]; then
      printf '%s\n' "$SANITY_FINDINGS" > "${AUDIT_DIR}/sanity-findings.txt"
      log "Full findings written to ${AUDIT_DIR}/sanity-findings.txt"
    fi
  fi
  warn "Keep the source server running for 24-48h before decommissioning it."
}
