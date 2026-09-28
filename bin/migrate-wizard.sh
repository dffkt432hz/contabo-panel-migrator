#!/usr/bin/env bash
# migrate-wizard.sh — the one command most people need.
#
# Walks through every decision step by step, asks only for what the chosen
# path actually requires, and then runs audit -> migrate -> DNS cutover ->
# sanity check across each account.
#
# Usage: bin/migrate-wizard.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

for _lib in common contabo-api audit-source audit-target migrate-account dns-cutover sanity-check; do
  # shellcheck disable=SC1090
  source "$REPO_ROOT/lib/${_lib}.sh" || { echo "Failed to load lib/${_lib}.sh" >&2; exit 1; }
done

AUDIT_DIR="$REPO_ROOT/audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$AUDIT_DIR"
chmod 700 "$AUDIT_DIR"
export AUDIT_DIR

DO_DNS_CUTOVER=0
ACCOUNT_LIST=""

banner() {
  cat <<'BANNER'

  ┌───────────────────────────────────────────────────────────────┐
  │            C O N T A B O   P A N E L   M I G R A T O R        │
  │        cPanel  ->  Webmin + LAMP (Virtualmin), guided         │
  └───────────────────────────────────────────────────────────────┘

BANNER
}

step_preflight() {
  section "Step 0 — Checking local prerequisites"
  preflight_local_deps || die "Install the missing tools listed above, then re-run."
  ok "All required local commands are present."
  log "Working directory for this run: $AUDIT_DIR"
}

step_scenario() {
  section "Step 1 — What are we migrating?"
  cat <<'MENU'
  1) cPanel/WHM  ->  Webmin + LAMP (Virtualmin)     [fully automated, recommended]
  2) cPanel/WHM  ->  bare Webmin (no virtual-server module)
  3) cPanel/WHM  ->  cPanel/WHM
MENU
  echo
  local choice
  read -r -p "Choose a scenario [1]: " choice </dev/tty
  choice="${choice:-1}"
  case "$choice" in
    1)
      REQUESTED_PANEL="virtualmin"
      ;;
    2)
      REQUESTED_PANEL="webmin"
      warn "Bare Webmin has no per-domain account model."
      warn "Files, databases and mail will still transfer, but vhost, PHP pool"
      warn "and catch-all setup all need the virtual-server module."
      confirm "Continue anyway?" || exit 0
      ;;
    3)
      echo
      ok "For cPanel -> cPanel, use WHM's own tool instead:"
      ok "  WHM > Transfer Tools > Copy an Account From Another Server"
      ok "It handles this natively and more completely than a third-party"
      ok "script can, because it understands cPanel's own account format."
      exit 0
      ;;
    *) die "Unrecognized choice: '$choice'" ;;
  esac
  export REQUESTED_PANEL
}

step_target_os() {
  section "Step 2 — Target server OS (informational)"
  cat <<'MENU'
  1) AlmaLinux 9      2) AlmaLinux 10     3) Rocky Linux 8 / 9
  4) Ubuntu 22.04     5) Ubuntu 24.04     6) Debian
MENU
  local _choice
  read -r -p "Choose [1]: " _choice </dev/tty
  log "Noted. Virtualmin installs cleanly on all of these."
  log "Install docs, if the target doesn't have it yet: https://www.virtualmin.com/download/"
}

step_connection_details() {
  section "Step 3 — Connection details"
  echo "-- Source (the old cPanel server) --"
  ask SOURCE_HOST     "  Host or IP"
  ask SOURCE_SSH_PORT "  SSH port" "22"
  ask SOURCE_SSH_USER "  SSH user" "root"
  ask SOURCE_SSH_KEY  "  SSH private key path (leave blank to use your agent/password)"
  echo
  echo "-- Target (the new Contabo VPS) --"
  ask TARGET_HOST     "  Host or IP"
  ask TARGET_SSH_PORT "  SSH port" "22"
  ask TARGET_SSH_USER "  SSH user" "root"
  ask TARGET_SSH_KEY  "  SSH private key path (leave blank to use your agent/password)"

  export SOURCE_HOST SOURCE_SSH_PORT SOURCE_SSH_USER SOURCE_SSH_KEY
  export TARGET_HOST TARGET_SSH_PORT TARGET_SSH_USER TARGET_SSH_KEY

  echo
  log "Testing connectivity to both servers..."
  if ! c_ssh source "true" 2>/dev/null; then
    err "Cannot reach the SOURCE server at ${SOURCE_HOST}:${SOURCE_SSH_PORT}."
    err "Tip: an instant 'connection refused' means nothing is listening on that"
    err "port; a long hang before failing means a firewall is dropping packets."
    die "Fix source connectivity and re-run."
  fi
  ok "Source reachable."

  if ! c_ssh target "true" 2>/dev/null; then
    err "Cannot reach the TARGET server at ${TARGET_HOST}:${TARGET_SSH_PORT}."
    die "Fix target connectivity and re-run."
  fi
  ok "Target reachable."

  # The source must not be the target. Easy to do by copy-paste, and the
  # consequences of a self-migration are genuinely unpleasant.
  if [[ "$SOURCE_HOST" == "$TARGET_HOST" ]]; then
    die "Source and target are the same host. Refusing to continue."
  fi
}

step_deploy_key() {
  section "Step 4 — Per-account SSH deploy key (optional)"
  log "Installs one shared public key on every migrated account, so you can"
  log "deploy to each site over SSH afterwards without using the root account."
  if confirm "Install a deploy key on every migrated account?"; then
    ask DEPLOY_PUBLIC_KEY "  Paste the PUBLIC key (ssh-ed25519 AAAA... or ssh-rsa AAAA...)"
    if [[ ! "${DEPLOY_PUBLIC_KEY:-}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-) ]]; then
      warn "That doesn't look like a public key. Skipping deploy-key setup."
      DEPLOY_PUBLIC_KEY=""
    fi
    export DEPLOY_PUBLIC_KEY
  fi
}

step_dns_credentials() {
  section "Step 5 — Contabo API credentials (for DNS cutover)"
  if ! confirm "Should this run also cut DNS over via the Contabo API?"; then
    log "Skipping DNS and certificate automation — you'll cut over manually."
    DO_DNS_CUTOVER=0
    return 0
  fi
  DO_DNS_CUTOVER=1

  cat <<'HELP'
  Where these come from:
    client_id / client_secret : Contabo panel > API Management > OAuth2 Clients
    API username              : your Contabo login email address
    API password              : Contabo panel > Security & Access > Password >
                                Send Link. This is a DEDICATED API password,
                                NOT your normal account login password —
                                using the login password fails silently.
HELP
  ask CONTABO_CLIENT_ID     "  client_id"
  ask CONTABO_CLIENT_SECRET "  client_secret" "" secret
  ask CONTABO_API_USER      "  API username (login email)"
  ask CONTABO_API_PASSWORD  "  API password (the dedicated one)" "" secret
  ask TARGET_PUBLIC_IP      "  Target server public IP (what DNS should point at)" "${TARGET_HOST}"
  export CONTABO_CLIENT_ID CONTABO_CLIENT_SECRET CONTABO_API_USER CONTABO_API_PASSWORD TARGET_PUBLIC_IP

  log "Verifying the credentials before we rely on them..."
  local token
  token=$(contabo_token)
  if [[ -z "$token" ]]; then
    err "Could not obtain a Contabo API token."
    err "This almost always means the API password is wrong — specifically, that"
    err "the normal account login password was used instead of the dedicated API"
    err "password. The API returns an empty token rather than an auth error."
    die "Fix the credentials and re-run."
  fi
  ok "Contabo API credentials verified."
}

step_account_selection() {
  section "Step 6 — Which accounts to migrate"
  cat <<'MENU'
  1) Everything found on the source server
  2) A specific list of domains I'll enter now
MENU
  local choice
  read -r -p "Choose [1]: " choice </dev/tty
  choice="${choice:-1}"
  if [[ "$choice" == "2" ]]; then
    echo "Enter one 'domain cpanel_user' pair per line. Blank line to finish:"
    local line
    while IFS= read -r line </dev/tty; do
      [[ -z "$line" ]] && break
      ACCOUNT_LIST+="${line}"$'\n'
    done
    [[ -z "$ACCOUNT_LIST" ]] && die "No accounts entered."
  fi
}

step_audit() {
  section "Step 7 — Audit"
  if ! audit_source_full; then
    err "The source server has problems that block an automated migration (see above)."
    exit 1
  fi

  if ! audit_target_full; then
    err "The target server is not ready for an automated migration (see above)."
    exit 1
  fi

  # Reality beats the menu: if the user picked Virtualmin but the target
  # only has bare Webmin, the detected value is the one everything else
  # must act on, and they should know about the mismatch now rather than
  # discovering it at the catch-all step of account thirty.
  if [[ "${REQUESTED_PANEL:-}" == "virtualmin" && "${TARGET_PANEL:-}" != "virtualmin" ]]; then
    warn "You chose the Virtualmin path, but the target reports: ${TARGET_PANEL:-none}"
    warn "Domain creation, PHP pools and catch-all setup will not work until"
    warn "Virtualmin is installed on the target."
    confirm "Continue with the limited feature set anyway?" || exit 0
  fi
}

step_migrate() {
  section "Step 8 — Migration"

  local accounts="$ACCOUNT_LIST"
  if [[ -z "$accounts" ]]; then
    accounts=$(source_account_pairs)
  fi
  if [[ -z "$accounts" ]]; then
    die "No accounts to migrate."
  fi

  local total
  total=$(printf '%s\n' "$accounts" | grep -c '[^[:space:]]' || true)
  log "About to migrate ${total} account(s)."
  confirm "Proceed? Nothing has been changed on either server yet." || { log "Stopped. Nothing was migrated."; exit 0; }

  # A here-string, not a pipe: a `while read` on the right of a pipe runs
  # in a subshell, so the issue counters in sanity-check.sh would reset to
  # zero and the final summary would always claim a clean run.
  local n=0 domain acct
  while read -r domain acct; do
    [[ -z "$domain" || -z "$acct" ]] && continue
    n=$((n + 1))
    section "[${n}/${total}] ${domain}"

    migrate_account "$domain" "$acct" "$acct"

    if [[ "$DO_DNS_CUTOVER" -eq 1 ]]; then
      if confirm "Cut DNS over for ${domain} now?"; then
        if dns_cutover_domain "$domain" "$TARGET_PUBLIC_IP"; then
          request_certificate "$domain"
        fi
      else
        log "Skipped DNS cutover for ${domain}. Run it later with:"
        log "  dns_cutover_domain '${domain}' '${TARGET_PUBLIC_IP}' && request_certificate '${domain}'"
      fi
    fi

    sanity_check_domain "$domain" "$acct" "$acct"
  done <<< "$accounts"

  sanity_report_summary

  section "Done"
  ok "Migrated ${n} account(s)."
  log "Run artifacts (account list, generated passwords, findings): ${AUDIT_DIR}"
  warn "Keep the source server live for 24-48 hours as a fallback before"
  warn "decommissioning it, and re-check mail flow in both directions first."
}

main() {
  banner
  step_preflight
  load_config
  step_scenario
  step_target_os
  step_connection_details
  step_deploy_key
  step_dns_credentials
  step_account_selection
  step_audit
  step_migrate
}

main "$@"
