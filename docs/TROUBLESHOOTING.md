# Troubleshooting & known gotchas

This is a running list of every real failure mode encountered while
building and running this toolkit against a production cPanel fleet. Most
of these are already worked around in the code (see the comment right
above the relevant function) — this page exists for the ones you'll still
hit yourself, and to explain *why* the code does what it does.

## Starting up

**`Failed to load lib/audit-source.sh` (or `audit-target.sh`) and the wizard exits.**
You are on the original 1.0.0 checkout, which shipped without those two
files. `git pull` to get 1.0.1 or later. `tests/run-tests.sh` now fails if
any library the wizard names is missing.

## SSH / connectivity

**A loop over SSH calls only seems to process the first item.**
Any `ssh` command inside a `while read` loop that's reading from a pipe
will, by default, also read (and drain) that loop's stdin — so the loop
silently stops after one iteration with no error. `c_ssh()` redirects
stdin from `/dev/null` for exactly this reason. If you write your own loop
calling it, keep that pattern.

**…but a database import through `c_ssh` imports nothing.**
The flip side of the fix above: because `c_ssh` discards stdin, piping
data *into* it (`mysqldump ... | c_ssh target "mysql db"`) feeds the
remote command an empty stream — and it "succeeds", having imported
nothing at all. Use `c_ssh_pipe()` whenever data needs to flow into the
remote command. This is the single nastiest failure mode in the whole
toolkit, because both halves look correct in isolation and the failure is
completely silent. `tests/run-tests.sh` asserts both behaviours.

**A `while read` loop's counters are all zero when it finishes.**
A loop on the right-hand side of a pipe (`printf ... | while read`) runs
in a *subshell*, so every variable it sets is discarded when it ends. This
silently made the post-migration summary report a clean run regardless of
how many problems were found. Feed loops with a here-string
(`done <<< "$data"`) instead of a pipe whenever the loop body sets
anything the caller needs to see.

**The wizard aborts immediately on macOS with an "unbound variable" error.**
macOS still ships bash 3.2 as `/bin/bash`, which treats an empty `"$@"`
as an unbound variable under `set -u`. Any loop over optional arguments
needs a `[[ $# -gt 0 ]]` guard around it. This toolkit is written to run
on bash 3.2, so it works with the stock macOS shell.

**Refused vs. timed out is the single most useful network diagnostic.**
`Connection refused` means packets reached the host and nothing is
listening on that port. `Operation timed out` means something upstream
(a firewall, a cloud provider's edge) is dropping the packets. "Can't
connect" alone tells you nothing — always check which one you got.

**rsync refuses "source and destination both remote."**
Not every provider's rsync build supports the agent-forwarding form of a
fully remote-to-remote copy. This toolkit always routes file transfers
through the machine running the script (`c_relay_copy`/`c_relay_tar`)
specifically to avoid this — direct server-to-server SSH trust between
the source and target also shouldn't exist anyway, for the obvious
security reason.

## Mail migration

**Mailboxes exist and accept logins, but are empty.**
A password *hash* only proves the account can log in — it says nothing
about message content. If a mailbox migration only ever copied
`/etc/shadow`-style hashes, historical mail was never actually moved.
Always verify with a real file count on both sides:
```bash
find <maildir> -type f \( -path '*/cur/*' -o -path '*/new/*' \) | wc -l
```
Target should be `>=` source (mail keeps arriving during the transfer
window on a live account); target `<` source means the transfer needs to
be redone from scratch, not delta-patched.

**A mailbox's messages are unreadable after transfer (Permission denied).**
Each mailbox has its *own* system UID, separate from the domain owner's
UID, sharing only the domain's group ID. A blanket
`chown -R domainuser:domainuser` on the mail home directory breaks every
mailbox under it. Always resolve and chown per-mailbox:
```bash
chown -R "$(id -u mailbox@domain):$(id -g domainowner)" /path/to/mailbox/home
```

**A mailbox transfer looks successful, then messages are missing later.**
Check for a default mail quota. A quota cap can truncate a large Maildir
transfer mid-write with *no error at transfer time* — it only shows up
later as `Disk quota exceeded` on a reindex, or as an unexplained message
count shortfall. Set quotas to unlimited *before* transferring, not after.

**Mail clients get "SSL alert 46 / certificate unknown" on connect.**
The certificate is missing a `mail.<domain>` SAN entry, so the mail
server's SNI-based certificate dispatch can't match the hostname the mail
client is actually connecting to. Reissue explicitly including it:
```bash
virtualmin generate-acme-cert --domain example.com --host example.com --host www.example.com --host mail.example.com
```

**Virtualmin's `create-alias --from "*"` (catch-all) fails with
"Invalid alias name: Missing or invalid username."**
This is a real bug on at least one Virtualmin build — the CLI's own
`--help` text documents `--from "*"` as the way to create a catch-all,
but its `valid_alias_name` validator rejects the literal `*` before that
code path is ever reached. `phase_catchall` in `lib/migrate-account.sh`
works around this entirely by calling the same internal
`create_domain_forward()` function the Virtualmin GUI itself uses,
bypassing the broken CLI validation.

## Database migration

**Every migrated site shows a database connection error.**
The database transferred fine — but its *user* was never recreated on the
target. A database with no user that can connect to it is useless, and
this is easy to miss because the dump/import half of the job reports
complete success. This toolkit reads the application's own config file
(`wp-config.php`, `.env`, `configuration.php`), recreates that exact user
with that exact password on the target, and grants it on both `localhost`
*and* `127.0.0.1`. Verify with `check_database_connectivity`, which makes
a real connection attempt as the application's own user rather than just
checking that things exist.

**A migrated site's DB password "doesn't work" even though it was copied.**
Check whether the password contains a quote character. A naive config
parser using a `[^'"]*` character class truncates the value at the first
quote, producing a user whose password is a prefix of the real one — and
the resulting "access denied" points you at permissions rather than at the
parser. The parsers here match the closing delimiter with a backreference
to the opening one, and `tests/run-tests.sh` covers passwords containing
`$`, `"`, `` ` ``, `'` and `*`.

**Keep the database *name* identical on the target.**
Renaming it (to match a new account prefix, say) means every application
config file referencing it has to be edited too — more work, and a step
that gets forgotten on exactly one site out of forty. Same name, same
user, same password means zero config edits.

**Don't trust `SHOW CREATE DATABASE` for charset.**
The schema-level default charset has been observed to disagree with the
*actual* per-table collation. Always check
`information_schema.tables.table_collation` per table before choosing a
`mysqldump --default-character-set=...` value — guessing wrong silently
corrupts non-ASCII text (diacritics, emoji, etc.) on import with no error.

**Row counts don't match after import.**
Never use `information_schema.tables.table_rows` to verify — it's an
*estimate* for InnoDB and has been observed stale immediately post-import.
Use a real `SELECT COUNT(*)` per table.

**A password containing `$` gets silently corrupted.**
Nested shell-quoting (`ssh ... 'mysql -e "..."'`) can mangle special
characters like a literal `$` in a password. Avoid nested quoting
entirely — write SQL to a temp file via a quoted heredoc and pipe it in,
rather than building one long quoted one-liner.

## PHP / application errors

**A migrated site 500s with nothing useful in the error log.**
Check PHP resource limits before anything else. A source cPanel box's
defaults (`memory_limit`, `upload_max_filesize`, `max_execution_time`,
etc.) are commonly 8-128x more generous than a fresh PHP-FPM install's
defaults, and hitting the new, lower limit produces an unlogged,
OOM-flavoured 500 rather than a clear PHP error. The
target audit checks this for you and offers to fix it. To run the check or
the fix by hand, from the repository root (with your target details in
`config/config.env`, and `AUDIT_DIR` pointing at the earlier run that
recorded the source's limits):

```
for l in common audit-source audit-target; do source lib/$l.sh; done
load_config
export AUDIT_DIR=audit-YYYYMMDD-HHMMSS
check_php_parity     # report only
fix_php_parity       # raise limits (never lowers), restart php-fpm, re-verify
```

`fix_php_parity` writes one drop-in file, `99-panel-migrator-limits.ini`,
next to the distro's own PHP config, so package upgrades cannot undo it.

**The PHP fix ran but a site still hits the old limit.**
The check reads the php *CLI*, and a per-pool PHP-FPM setting
(`php_admin_value[memory_limit]` and friends in a pool file) overrides
`php.ini` for that pool. `check_php_parity` lists any pool files that set
their own values — edit those too. The source's limits are likewise read
from its php CLI, so a per-domain MultiPHP override on the source is not
visible to the audit.

**A write fails with what looks like a permissions or syntax error.**
Check disk quota first — `virtualmin list-domains --domain <domain>
--multiline | grep -i quota`. A capped quota produces confusing failures
in totally unrelated-looking commands (a `sed -i` on `.htaccess`, for
example) well after the quota was actually exceeded by something else.

**The audit reports addon/parked domains, but only the main domain migrated.**
Correct, and deliberate: the pipeline migrates each account's main domain.
Run it again for the addon domains (choose "a specific list of domains" at
account selection), or migrate them by hand.

**A long transfer stalls or the connection is refused partway through.**
The source audit lists any security layer it finds (CSF, Imunify360,
cPHulk, fail2ban). These rate-limit or ban a host that opens many SSH
connections in a row, which is exactly what a transfer does. Whitelist the
machine running the wizard on both servers before starting (for CSF:
`csf -a <ip>`), and check you have not been banned if connections start
being refused.

**The target audit refuses to continue because of disk space.**
It compares the source's real footprint (files and mail from `du`, plus
the size of the databases being migrated) against the target's free space,
with a 10% margin, and databases get extra room for import overhead. Free
space or resize the VPS, then re-run; nothing has been copied yet.

## Virtualmin CLI quirks

**A `--multiline` output loop silently does nothing.**
Virtualmin's own `--multiline` CLI output indents field names with
leading whitespace (`    Name: Default Plan`), so an anchored
`grep "^Name:"` never matches — the loop *looks* like it ran (no error)
but processed zero lines. Use `vm_field()` from `lib/common.sh` instead of
grepping multiline output directly.

**A `sed -i` config edit reports no error but changes nothing.**
Don't assume exact spacing in a config file (`key=value` vs
`key = value`). Use a tolerant pattern
(`^[[:space:]]*key[[:space:]]*=.*`) — see `c_set_kv()` in
`lib/common.sh` — and always re-read the value back after any scripted
config edit to confirm it actually changed.

## DNS / Contabo API

**Every API call needs its own `x-request-id` header, auth included.**
Missing it returns 400 regardless of whether the credentials are correct.

**The access token comes back `null` with no clear error.**
Almost always means the wrong password was used — Contabo's API requires
a *separate, dedicated* API password (generated via Security & Access ->
Password -> Send Link in the Contabo panel), not your normal account
login password. Using the login password fails silently rather than with
an authentication error.

**A domain using a third-party mail provider (Zoho, Microsoft 365, etc.)
stops receiving mail after DNS cutover.**
Its SPF record almost certainly had an `include:` mechanism that got
blindly overwritten. `contabo_dns_upsert_spf()` in `lib/contabo-api.sh`
always preserves existing `include:` entries and only swaps the `ip4:`
mechanism — never hand-roll a full SPF replacement.

**`www` stops resolving after cutover.**
If `www.<domain>` was a CNAME and the cutover created an A record for the
same name, the zone now contains both — which is invalid, and resolvers
handle it unpredictably. `dns_cutover_domain()` checks for an existing
CNAME first and leaves it alone (a CNAME to the apex follows the apex
automatically, so it needs no update).

**A site's homepage disappears after migration.**
Virtualmin's `create-domain` drops a placeholder `index.html` into
`public_html`, and cleanup logic that deletes `index.html` whenever an
`index.php` exists will happily delete a *real* homepage on any site that
legitimately has both. The transfer step here records whether the source
had its own `index.html` *before* copying, and only removes the file when
the source had none.

**A certificate request fails right after DNS cutover.**
DNS may not have propagated yet — Let's Encrypt's HTTP-01 validator
connects to whatever IP the domain *actually, publicly* resolves to at
the moment of the request. `wait_for_propagation()` polls a public
resolver before the cert step runs for exactly this reason. Repeated
failed attempts trigger Let's Encrypt's own rate limit (~1 hour lockout)
with no way around it but waiting — fix the underlying cause first, don't
just retry.
