# Changelog

## 1.0.1 — 2026-09-28

**Fixed: the wizard could not start.** `lib/audit-source.sh` and
`lib/audit-target.sh` were missing from the 1.0.0 commit, so
`bin/migrate-wizard.sh` aborted while loading libraries. The offline suite
never sourced them, which is why it kept passing. Both files are restored:

- *Source audit* — read-only. Account discovery (`/etc/trueuserdomains`,
  falling back to `/var/cpanel/users`), platform detection, database name /
  user / per-table charset / size (never the password), real mailboxes,
  catch-all classification, addon and parked domains the pipeline does not
  migrate, PHP versions and limits, security-stack detection, and each
  account's disk footprint. Writes `source-accounts.tsv` and
  `source-php-limits.env` to the run directory.
- *Target audit* — panel detection (`TARGET_PANEL`), required tools, service
  status, default-plan quota cap, security stack, PHP-limits parity
  (`check_php_parity`) with a non-lowering, read-back-verified fix
  (`fix_php_parity`), and a disk check that adds files and databases together
  when they share a filesystem.
- The wizard now stops if the source audit fails, instead of ignoring it.

**Security hygiene.**

- `.gitignore` now covers every `config/*.env`, `.env*`, per-run output
  (`generated-passwords.tsv`, `source-accounts.tsv`, `sanity-findings.txt`)
  and common key names, not just `config/config.env`.
- A test fixture that used a real-looking account name now uses a neutral one.
- The test suite now fails if a private key, API token or non-documentation
  IP address appears in any tracked file, and if `.gitignore` stops covering
  env files.
- Added `SECURITY.md` (private reporting, how secrets are handled, what to
  do after a leak).

**Tests and CI.** The suite grew from 28 to 73 assertions, adding: a wiring
test that every library the wizard sources exists, loads and defines what
the wizard calls; syntax checks of every script; php.ini value comparison;
disk-headroom math; source discovery against a fixture tree; and the PHP
parity check and fix against temp directories. GitHub Actions now runs the
suite on Linux and on macOS's stock bash 3.2, plus ShellCheck, replacing the
static README badges with a live one.

**Docs.** README, ARCHITECTURE (audit outputs, how secrets move),
SUPPORTED-SCENARIOS (addon domains), and TROUBLESHOOTING (startup failure,
PHP overrides, security-layer bans, disk check, addon domains) updated; the
clone URL placeholder in the quick start is fixed.

## 1.0.0 — Initial release

**Wizard.** Interactive entrypoint (`bin/migrate-wizard.sh`) covering
scenario selection, local dependency preflight, connection setup and
reachability testing, optional deploy-key install, optional Contabo DNS
automation with credential verification up front, and account selection.
Per-domain confirmation before any DNS cutover.

**Source audit.** Per-account platform detection (WordPress, Laravel,
Joomla, generic PHP, static), symlinked-`public_html` detection, real
database discovery with true per-table collation, real mailbox and
forwarder discovery, existing catch-all detection, PHP version and limit
inventory, and security-stack detection (cPHulk, CSF, Imunify360,
ModSecurity, fail2ban, ClamAV).

**Target audit.** Control-panel detection (Virtualmin / cPanel / bare
Webmin / none), PHP resource-limit parity check with a one-command fix,
default-quota-cap detection, security-stack detection, and a disk-space
check that compares the source's actual footprint against the target's
free space before anything is copied.

**Migration pipeline.** Domain creation (idempotent), file transfer
relayed through the operator's machine rather than server-to-server,
symlinked-`public_html` handling, safe placeholder-file cleanup, database
migration preserving the original name/user/password so application
configs need no edits, mailbox migration covering both password hashes and
full historical message content, and domain-wide catch-all setup.

**DNS and certificates.** Contabo API integration with error-tolerant
parsing, CNAME-aware `www` handling, `include:`-preserving SPF rewrites,
`mail.<domain>` handling, propagation polling before certificate issuance,
and issuer-vs-subject certificate verification.

**Sanity checks.** File counts, a real database connection attempt using
the application's own credentials, HTTP/HTTPS response codes with
redirect-chain following, certificate validity and `mail.<domain>` SAN
coverage, effective PHP limits, quota headroom, and DKIM/catch-all
presence — each failure printing the exact command that fixes it.

**Tests.** `tests/run-tests.sh`, 28 assertions, runs fully offline against
a mock SSH transport.

### Notes on provenance

Every workaround here exists because something specific broke, silently,
during a real production cPanel-fleet migration and had to be
root-caused by hand. `docs/TROUBLESHOOTING.md` documents each one
alongside the symptom that led to it.

A pre-release audit pass of this codebase found and fixed several further
bugs before first publication, all covered by tests:

- Database imports piped through the stdin-discarding SSH wrapper would
  have imported nothing while reporting success.
- Application database *users* were never recreated on the target, which
  would have left every migrated site showing a database connection error.
- Config parsers truncated any database password containing a quote
  character, producing users whose passwords silently didn't work.
- Counters incremented inside piped `while read` loops reset in the
  subshell, so the post-migration summary always reported a clean run.
- Placeholder-`index.html` cleanup could delete a site's real homepage.
- An unguarded `"$@"` aborted the wizard under bash 3.2 (stock macOS).
- Creating a `www` A record alongside an existing CNAME produced an
  invalid zone.
