# Changelog

## 1.0.2 — 2026-09-28

A code review of the whole pipeline found the defects below. Each has a
regression test. For the most serious ones (charset, SQL escaping, ignored API
errors, DNS after a failed migration, mailbox lookup) the bug was re-introduced
on purpose to confirm the suite fails; the rest are covered by tests but were
not mutation-checked.

**Data-loss and corruption fixes**

- **Non-ASCII text lost on import.** A `utf8` (mb3) database, or any database
  that was not `latin1` or `utf8mb4`, fell through to a `latin1` dump, which
  silently turns every character latin1 cannot hold (Romanian ă ș ț among
  them) into `?`. The dump charset is now chosen from the real charset of
  every table: the tables' own charset when there is exactly one, otherwise
  `utf8mb4`; `latin1` only for genuinely `latin1` data.
- **Wrong or missing DB user password.** Passwords containing `'` broke the
  SQL and passwords containing `\` were silently altered. The user SQL is now
  escaped and sent over stdin. `CREATE USER IF NOT EXISTS` is followed by
  `ALTER USER`, so re-running fixes a user left with a different password. A
  site whose config yields no password no longer gets a passwordless MySQL
  user with full rights.
- **Another account's databases pulled in.** The fallback matched
  `LIKE '<user>%'` (where `_` is a wildcard and there is no boundary), so
  account `web` also migrated `webshop_*`. It now matches the literal
  `<user>_` prefix. Databases the pipeline does not migrate (anything other
  than the one the app config names) are now listed with a warning instead of
  being left behind silently.
- **Wrong mailbox hash.** The lookup used a regex prefix, so `john.smith`
  could also match `john-smith`. It now matches the exact local part.

**DNS fixes**

- **API errors were swallowed.** Every DNS call's result was discarded, so a
  rejected update still printed "DNS updated". Calls now succeed only on
  HTTP 2xx and the cutover stops at the first failure.
- **A verification TXT record could be overwritten.** The SPF update replaced
  "the first TXT record at the apex", which is often a site-verification
  record, and left the real SPF untouched. The real SPF record is now found by
  its content and updated by id.
- **SPF mechanisms were dropped.** The rewrite kept only `include:` and
  replaced everything else, loosening `-all` to `~all` and discarding other
  `ip4:`, `a:`/`mx:` and `redirect=`. It now adds the new server and keeps
  everything else; a `redirect=` record is left unchanged.
- **The zone is checked first.** A domain whose DNS is not hosted at Contabo
  no longer results in writes into a zone nobody resolves.
- **Hostname as target IP.** The wizard defaulted the DNS target to
  `TARGET_HOST`, which is often a hostname, creating an invalid A record. An
  IPv4 is now required (validated in the wizard and again at cutover).
- **TTLs are preserved** on update instead of being forced to 86400 seconds,
  which had turned a short, rollback-friendly TTL into a full day.
- The certificate host list is now shell-quoted.

**Wizard**

- A failed account migration is no longer followed by a DNS cutover offer or
  a sanity check. The run summarises failed accounts and exits non-zero.
- The wizard file can be sourced without side effects (used by the tests).

**Checks and audits**

- The database connection test passes the password through `MYSQL_PWD` and
  stdin instead of a command-line argument.
- The catch-all check anchored its match (`example.com` no longer matches
  `@example.com.au`), database existence checks use exact matches instead of
  `LIKE`, and the PHP `memory_limit` check compares against the source's real
  value instead of guessing what a "stock" value is.
- An unreadable `df` no longer reports "0 MB free"; an unreadable target PHP
  is reported as "cannot check" instead of a limits gap; the source audit now
  sizes and lists prefix-matched databases when the app config yields none.
- File counts follow symlinks on both sides, so a tree containing symlinked
  directories no longer produces a false mismatch.

**Tests and docs.** 73 -> 123 assertions, including a fake Contabo API, a
fake `mysql`, and the wizard driven through failing and passing accounts. The
README, TROUBLESHOOTING, ARCHITECTURE, SUPPORTED-SCENARIOS and SECURITY docs
are corrected to match the code (DNS cutover never touched DKIM, contrary to
what two of them said), and `config.example.env` now explains quoting values
that contain `$`.

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
