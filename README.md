# Contabo Panel Migrator

![bash](https://img.shields.io/badge/bash-3.2%2B-121011?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/platform-AlmaLinux%20%7C%20Rocky%20%7C%20Ubuntu%20%7C%20Debian-lightgrey)
![source](https://img.shields.io/badge/source-cPanel%20%2F%20WHM-FF6C2C)
![target](https://img.shields.io/badge/target-Virtualmin%20%2F%20Webmin-7952B3)
![license](https://img.shields.io/badge/license-MIT-yellow)
[![CI](https://github.com/dffkt432hz/contabo-panel-migrator/actions/workflows/ci.yml/badge.svg)](https://github.com/dffkt432hz/contabo-panel-migrator/actions/workflows/ci.yml)

**Move an entire cPanel server to Webmin + LAMP without losing a single mailbox.**

An interactive toolkit that migrates an entire cPanel server — every
account's files, databases, mailboxes (including full historical message
content, not just working logins), and DNS — to a fresh Contabo VPS
running Webmin/Virtualmin, with a guided wizard, a pre-flight audit of
both servers, and a post-migration sanity check that tells you exactly
what to fix if anything's off.

It's built from a real production migration: every workaround in this
codebase exists because a specific thing actually broke, silently, and
had to be root-caused by hand. That history is documented in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — read it before you
hit the same wall.

## Why this exists

Moving off cPanel is usually a choice between two bad options: pay for
another cPanel license on the new box (no real technical reason to,
sometimes just done because it's the safe/known path), or migrate by
hand and inevitably miss something — a mailbox that still exists on paper
but whose messages never made it over, a PHP limit that silently 500s a
heavy site, a catch-all address nobody remembered was even set up on
the old server. This toolkit exists to make the second option actually
safe, by encoding every one of those gotchas as a check that runs
automatically, every time.

## What it actually does

1. **Scans the source server** (read-only) — every real cPanel account, what
   platform each site runs (WordPress, Laravel, Joomla, generic PHP,
   static), its real database(s) and their actual per-table charset, its
   real mailboxes (not the account name — the *real* addresses), any
   catch-all routing already configured, addon/parked domains the
   pipeline will *not* cover, total size, PHP limits, and what security
   layers (CSF, Imunify360, cPHulk, ModSecurity, fail2ban, ClamAV) could
   interfere with a long transfer. The per-account inventory is saved to
   the run's `audit-*/` directory.
2. **Audits the target server** — confirms Webmin/Virtualmin is actually
   installed and its services are running, checks that the tools the
   pipeline needs are present, compares the target's PHP limits with the
   source's (and offers a one-step, non-lowering fix), flags a quota cap
   that would silently truncate a large transfer, and checks free disk
   against the source's real footprint before anything is copied.
3. **Migrates everything, per account, in the order that works** —
   domain creation, file transfer, database import, SSH deploy-key
   install, full mailbox migration (password + real message content),
   and catch-all address setup. Databases keep their original name, user
   and password, so the application's own config file needs **no edits**
   after the move.
4. **Cuts DNS over via the Contabo API** — A/www records and an
   SPF-preserving TXT update (never touches MX/NS/SOA/DMARC), waits for
   real propagation, then requests a Let's Encrypt certificate — in that
   order, because doing it out of order is exactly how a cert request
   fails.
5. **Runs a sanity check with the fix already written for you** — file
   count mismatches, a real database connection attempt as the
   application's own user, wrong HTTP/HTTPS response codes, missing or
   self-signed certificates, missing mail-hostname SAN entries, PHP
   limits that didn't actually take effect, quota caps, missing DKIM or
   catch-all setup. Every `[WARN]`/`[FAIL]` line prints the exact command
   to fix it.

Throughout, "the command didn't error" is never accepted as evidence that
something worked. File counts, row counts and message counts are compared
between the two servers; the database check opens a real connection with
the application's real credentials; the certificate check compares issuer
against subject rather than pattern-matching a CA name that changes over
time.

## Quick start

```bash
git clone https://github.com/dffkt432hz/contabo-panel-migrator.git
cd contabo-panel-migrator
cp config/config.example.env config/config.env   # optional — pre-fill what you already know
bin/migrate-wizard.sh
```

The wizard asks for everything it needs, one step at a time, and only
asks for what your chosen path actually requires — if you skip DNS
automation, it never asks for Contabo credentials at all.

```
Step 1 — What are we migrating?
  1) cPanel/WHM  -> Webmin + LAMP (Virtualmin)   [fully automated, recommended]
  2) cPanel/WHM  -> bare Webmin (no virtual-server module)
  3) cPanel/WHM  -> cPanel/WHM
```

See [`docs/SUPPORTED-SCENARIOS.md`](docs/SUPPORTED-SCENARIOS.md) for what
each path actually automates.

## Requirements

- A machine to run the wizard from (your laptop, a jump box, CI) with
  `bash`, `ssh`, `rsync`, `curl`, and `python3` — nothing needs to be
  installed on either the source or target server itself.
- Root SSH access to both servers.
- Virtualmin installed on the target if you're using the fully-automated
  scenario (the wizard checks and tells you if it's missing).
- A Contabo account + a **dedicated API password** (Security & Access ->
  Password -> Send Link in the Contabo panel — not your normal login
  password) if you want automated DNS cutover.

## Safety notes

- Both audits are read-only. The only thing before the migration itself
  that can change a server is the optional PHP-limits fix, which asks
  first, only ever *raises* a limit, writes one separate drop-in file
  (never the distro's `php.ini`), and reads the values back to confirm.
- Every SSH command is fully scripted and logged — nothing is run
  interactively "by feel."
- File transfers never go directly server-to-server; they're always
  relayed through the machine running the wizard, so the source and
  target never need standing SSH trust in each other.
- DNS cutover only ever touches A/www/SPF/DKIM records, and SPF is
  rewritten in an `include:`-preserving way so a domain on Zoho/Microsoft
  365/etc. doesn't lose outbound mail deliverability.
- Nothing on the source server is ever deleted or disabled by this
  toolkit. Decommissioning the source is a manual, deliberate step you
  take after your own monitoring window — not something a script decides
  for you.

## Credentials and security

This repository contains no credentials, keys, or server addresses, and
the test suite fails if one ever sneaks in. Real configuration
(`config/*.env`) and every run's output (`audit-*/`, which includes the
passwords generated for new domains) are git-ignored. Contabo secrets are
read without echo; database passwords are never printed or recorded by the
audit. Details, and what to do if you commit a secret by accident, are in
[`SECURITY.md`](https://github.com/dffkt432hz/contabo-panel-migrator/blob/main/SECURITY.md).

## Tests

```
tests/run-tests.sh
```

Runs offline — no servers needed. Remote execution is exercised through a
mock `ssh` that runs commands locally, so the real wrappers are tested
rather than stubbed out. The suite covers the failure modes that are
hardest to spot by reading the code: stdin handling around SSH (a loop
that silently processes one item; a database import that silently imports
nothing), config parsers against passwords containing `$`, `"`, `` ` ``, `'` and `*`, counters that reset inside subshells, and API parsing given
malformed or error responses. It also checks that every library the wizard
loads exists and defines what the wizard calls, that source discovery
(accounts, platforms, catch-alls, addon domains) and the PHP-limits
check/fix behave correctly, and that nothing credential-shaped is committed.

CI runs the suite on Linux and on macOS's stock bash 3.2, plus ShellCheck.

## Repository layout

```
bin/migrate-wizard.sh     — interactive entrypoint, start here
lib/common.sh             — SSH wrappers, logging, config loading
lib/contabo-api.sh        — Contabo DNS API (auth, upsert, SPF-preserving update)
lib/audit-source.sh       — read-only source scan (accounts, platform, DB, mail, size, PHP, security)
lib/audit-target.sh       — target readiness (panel, tools, PHP parity + fix, quota, disk, security)
lib/migrate-account.sh    — the actual per-account migration pipeline
lib/dns-cutover.sh        — DNS cutover + certificate issuance, in the right order
lib/sanity-check.sh       — post-migration verification + suggested fixes
config/config.example.env — copy to config/config.env and fill in what you know
docs/ARCHITECTURE.md      — how it fits together and why
docs/TROUBLESHOOTING.md   — every real failure mode hit building this, and its fix
docs/SUPPORTED-SCENARIOS.md — which source/target combos are automated vs. manual
tests/run-tests.sh        — offline test suite (no servers required)
.github/workflows/ci.yml  — tests on Linux + macOS bash 3.2, and ShellCheck
SECURITY.md               — reporting, credential handling, what to do after a leak
```

## Compatibility

Runs on bash 3.2 and later, so the stock `/bin/bash` on macOS works
without installing anything. Target servers are assumed to be Linux with a
POSIX shell; Windows Server images are out of scope.

## License

MIT — see [`LICENSE`](LICENSE).
