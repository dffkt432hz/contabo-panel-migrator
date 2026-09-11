#!/usr/bin/env bash
# dns-cutover.sh — Step 5: point DNS at the new server via the Contabo API,
# then, only once DNS has really settled, request a certificate.
#
# The order is load-bearing. Let's Encrypt's HTTP-01 validator resolves the
# domain publicly and connects to whatever IP it currently points at, so a
# certificate requested before cutover fails — and repeated failures hit a
# rate limit (roughly a one-hour lockout) that nothing can shortcut.
#
# Records deliberately NOT touched: MX, NS, SOA, DMARC, and any
# site-verification TXT records. Automatically rewriting those is an
# excellent way to break a domain in a manner nobody notices until mail
# stops arriving days later.

dns_cutover_domain() {
  local domain="$1" target_ip="$2"
  section "DNS cutover: $domain -> $target_ip"

  local token
  token=$(contabo_token)
  if [[ -z "$token" ]]; then
    err "Could not obtain a Contabo API token."
    err "The most common cause is using your normal account login password"
    err "instead of the dedicated API password (Contabo panel > Security &"
    err "Access > Password > Send Link). That failure is silent — the API"
    err "returns a null token rather than an authentication error."
    return 1
  fi

  # Apex A record.
  log "  Updating A record for ${domain}..."
  contabo_dns_upsert "$domain" "$token" "$domain" "A" "$target_ip" >/dev/null

  # www — but only as an A record if it isn't already a CNAME. A CNAME and
  # an A record cannot coexist for the same name; creating one alongside
  # the other produces an invalid zone that resolvers handle unpredictably.
  local www_cname
  www_cname=$(contabo_dns_find_id "$domain" "$token" "www.${domain}" "CNAME")
  if [[ -n "$www_cname" ]]; then
    log "  www.${domain} is a CNAME — leaving it alone (it will follow the apex)."
  else
    log "  Updating A record for www.${domain}..."
    contabo_dns_upsert "$domain" "$token" "www.${domain}" "A" "$target_ip" >/dev/null
  fi

  # mail.<domain>, only if it already exists. Creating it where it never
  # existed would be inventing a hostname the domain's mail setup does not
  # use; leaving a stale one pointed at the old server breaks mail clients.
  local mail_a
  mail_a=$(contabo_dns_find_id "$domain" "$token" "mail.${domain}" "A")
  if [[ -n "$mail_a" ]]; then
    log "  Updating A record for mail.${domain}..."
    contabo_dns_upsert "$domain" "$token" "mail.${domain}" "A" "$target_ip" >/dev/null
    DOMAIN_HAS_MAIL_HOST=1
  else
    DOMAIN_HAS_MAIL_HOST=0
  fi
  export DOMAIN_HAS_MAIL_HOST

  # SPF, rewritten in an include:-preserving way. A domain using a
  # third-party mail provider (Zoho, Microsoft 365) carries include:
  # mechanisms that a blind overwrite destroys, silently breaking its
  # outbound deliverability.
  log "  Updating SPF (preserving any existing include: mechanisms)..."
  contabo_dns_upsert_spf "$domain" "$token" "$target_ip" >/dev/null

  ok "  DNS updated. MX, NS, SOA, DMARC and verification TXT records untouched."

  log "  Waiting for public DNS to reflect the change..."
  wait_for_propagation "$domain" "$target_ip"
}

wait_for_propagation() {
  local domain="$1" expected_ip="$2"
  local tries=0 max_tries=30 resolved
  while [[ $tries -lt $max_tries ]]; do
    resolved=$(resolve_a_record "$domain")
    if [[ "$resolved" == "$expected_ip" ]]; then
      ok "  ${domain} now resolves to ${expected_ip} on a public resolver."
      return 0
    fi
    tries=$((tries + 1))
    printf '\r  waiting... (%s/%s, currently resolving to: %s)   ' \
      "$tries" "$max_tries" "${resolved:-no answer}"
    sleep 10
  done
  echo
  warn "  ${domain} still does not resolve to ${expected_ip} after 5 minutes."
  warn "  This is usually just slow propagation rather than a mistake. Skipping"
  warn "  the certificate request for now — re-run request_certificate '${domain}'"
  warn "  once it settles. Requesting it early just burns Let's Encrypt attempts."
  return 1
}

request_certificate() {
  local domain="$1"
  section "Requesting Let's Encrypt certificate for $domain"

  # Explicit --host list on purpose. A default request that also picks up
  # admin.<domain> / webmail.<domain> aliases fails the ENTIRE multi-name
  # request, because those hostnames redirect to panel ports that the
  # HTTP-01 validator will not follow.
  local -a hosts=(--host "$domain" --host "www.${domain}")

  # Include mail.<domain> when it exists. Omitting it is the exact cause of
  # the "SSL alert 46 / certificate unknown" failure that takes every mail
  # client on a domain offline while the website looks perfectly fine:
  # Dovecot's SNI dispatch has no certificate matching the hostname the
  # mail client actually connects to.
  if [[ "${DOMAIN_HAS_MAIL_HOST:-0}" -eq 1 ]]; then
    local mail_resolved
    mail_resolved=$(resolve_a_record "mail.${domain}")
    if [[ -n "$mail_resolved" ]]; then
      hosts+=(--host "mail.${domain}")
      log "  Including mail.${domain} in the certificate (required for mail clients)."
    else
      warn "  mail.${domain} has a record but doesn't resolve yet — excluding it"
      warn "  from this request so it can't fail the whole certificate."
    fi
  fi

  if ! c_ssh target "virtualmin generate-acme-cert --domain $(printf '%q' "$domain") ${hosts[*]}"; then
    err "  Certificate request failed for ${domain}."
    err "  Check the domain's .htaccess for a catch-all rewrite that blocks"
    err "  /.well-known/acme-challenge/ before retrying — and do not retry in a"
    err "  loop, since repeated failures trigger a ~1 hour rate-limit lockout."
    return 1
  fi

  c_ssh target "virtualmin create-redirect --domain $(printf '%q' "$domain") --path / --redirect $(printf '%q' "https://${domain}/") --http --fix-wellknown --code 301" \
    || warn "  Could not set up the HTTP->HTTPS redirect (the certificate itself is fine)."

  verify_certificate "$domain"
}

verify_certificate() {
  local domain="$1"
  # Checked from the target itself against 127.0.0.1 with an explicit SNI
  # name. Connecting to the public IP from the box itself can fail or
  # behave oddly depending on the network's hairpin NAT behaviour, which
  # would look like a certificate problem when it isn't one.
  local issuer subject
  issuer=$(c_ssh target "echo | openssl s_client -connect 127.0.0.1:443 -servername $(printf '%q' "$domain") 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null" | sed 's/^issuer=//')
  subject=$(c_ssh target "echo | openssl s_client -connect 127.0.0.1:443 -servername $(printf '%q' "$domain") 2>/dev/null | openssl x509 -noout -subject 2>/dev/null" | sed 's/^subject=//')

  if [[ -z "$issuer" ]]; then
    warn "  Could not read a certificate for ${domain} — check it manually."
    return 1
  fi
  # A self-signed certificate has an issuer identical to its subject; that
  # comparison is stable, unlike matching on a particular CA's current
  # intermediate name, which changes over time.
  if [[ "$issuer" == "$subject" ]]; then
    warn "  ${domain} is still serving a SELF-SIGNED certificate (issuer == subject)."
    return 1
  fi
  ok "  Real certificate active for ${domain} (issuer: ${issuer})"
}
