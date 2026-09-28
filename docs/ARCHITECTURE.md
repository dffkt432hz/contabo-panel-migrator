# Architecture

## Design goals

1. **Nothing runs on the source or target server itself.** The wizard runs
   from a third machine (your laptop, a jump box, a CI runner) and drives
   both servers over SSH. Neither server needs anything installed for this
   toolkit to work beyond what a normal cPanel box and a normal Virtualmin
   box already have.
2. **Every phase is independently callable and safe to re-run.** A failed
   migration resumes from the step that failed, not from scratch. File
   transfers, database imports, and mailbox creation all check
   before-state where practical rather than blindly re-doing work.
3. **No destructive action is ever chained after a step that might fail.**
   Cleanup (removing staging directories, deleting placeholder files) is
   always a separate, explicit, final step — never bundled into a script
   whose earlier steps might fail and leave things in a state where an
   unconditional `rm -rf` further down would do real damage.
4. **Everything that can be verified, is.** File counts, row counts,
   message counts, HTTP status codes, and certificate SAN lists are
   checked with real commands against both servers, never assumed from
   "the command didn't print an error."

## Flow

```mermaid
flowchart TD
    A[bin/migrate-wizard.sh] --> B[Step 1-2: scenario + target OS]
    B --> C[Step 3: connection details + reachability test]
    C --> D[Step 4-5: deploy key + Contabo API credentials]
    D --> E[Step 6: account selection]
    E --> F[audit-source.sh: read-only scan: accounts, platform, DB, mail, size, PHP, security]
    F --> G[audit-target.sh: panel, tools, PHP parity, quota, disk, security]
    G --> H{Proceed?}
    H -- no --> Z[Stop, nothing changed]
    H -- yes --> I[migrate-account.sh, per account]
    I --> I1[1. create-domain]
    I1 --> I2[2. transfer files]
    I2 --> I3[3. migrate database]
    I3 --> I4[4. install deploy key]
    I4 --> I5[5. migrate mail: hashes + real content]
    I5 --> I6[6. catch-all address]
    I6 --> J[dns-cutover.sh: Contabo API]
    J --> K[request real certificate]
    K --> L[sanity-check.sh: verify + suggest fixes]
    L --> E
    E -->|all accounts done| M[Final summary report]
```

## Why file transfers never go straight server-to-server

Two independent reasons, either one of which is sufficient on its own:

- **It usually doesn't work anyway.** Many rsync builds refuse a
  source-and-destination-both-remote invocation outright
  (`The source and destination cannot both be remote.`), and even where it
  technically works it depends on SSH agent forwarding being configured
  correctly on a machine you may not control.
- **It shouldn't work, on security grounds.** The source and target
  servers should never have standing SSH trust in each other — if either
  one is ever compromised, that trust relationship is exactly the kind of
  thing that turns a single-server incident into a two-server one. Routing
  every transfer through the operator's own machine (`c_relay_copy` /
  `c_relay_tar` in `lib/common.sh`) means neither server needs to know the
  other exists.

## Why the mail migration is two separate phases

A source panel's `/etc/shadow`-style password hash and a mailbox's actual
message content are transferred by completely different mechanisms, and
conflating them is the single most common way this kind of migration goes
wrong silently:

- The **hash** proves a login will work. Copying `virtualmin create-user
  --encpass '<hash>'` from the source's real hash produces a byte-identical
  working password with zero user-visible change — but creates an *empty*
  mailbox.
- The **content** (inbox, sent, trash, custom folders — everything) has to
  be moved as a raw Maildir filesystem transfer, because only a hash (never
  a plaintext password) is ever available to a migration script, which
  rules out IMAP-level synchronization tools like `imapsync`.

A migration that only does the first half looks completely successful
(users can log in!) while silently leaving every user's mail history
behind. This toolkit always does both, and verifies message counts on both
sides rather than trusting "no error" as proof of a complete transfer.

## What the audits produce

Both audits run before anything is copied, and the second consumes what the
first learned:

| Produced by | Where | Used by |
|---|---|---|
| `audit_source_full` | `SOURCE_ACCOUNT_COUNT`, `SOURCE_TOTAL_KB`, `SOURCE_DB_KB` (shell variables) | `check_target_disk` compares them with the target's free space |
| `audit_source_full` | `audit-*/source-accounts.tsv` (domain, user, platform, database, charset, mailbox count, catch-all, size) | the operator; never contains a password |
| `audit_source_full` | `audit-*/source-php-limits.env` | `check_php_parity` / `fix_php_parity` on the target |
| `audit_target_full` | `TARGET_PANEL` (`virtualmin` \| `webmin` \| `cpanel` \| `none`) | `migrate-account.sh` and `sanity-check.sh` gate Virtualmin-only steps on it |

`audit_source_full` returns non-zero (and the wizard stops) if the source is
missing a tool the pipeline needs or has no accounts; `audit_target_full`
returns non-zero if there is no usable Webmin/Virtualmin, a required tool is
missing, or the target lacks room for the source's real footprint. Because
the results are shell variables, the wizard must call both functions
directly — never inside a pipe or `$(...)`, which would discard them.

## How secrets move through the toolkit

- Contabo credentials are prompted for without echo, or read from a
  git-ignored `config/*.env`. They live in environment variables for the
  duration of the run and are never written to the audit directory.
- A site's database password is read from that site's own config file,
  used once to recreate the database user on the target, and never printed
  or logged by the audit.
- Passwords generated for new domains go to
  `audit-*/generated-passwords.tsv` (mode 600, in a 700 directory).
- Everything above is git-ignored, and the offline test suite scans the
  tracked files for private keys, API tokens and real IP addresses.

## Extending to other source panels

`lib/audit-source.sh`'s account/domain/mailbox discovery currently assumes
cPanel (`/etc/trueuserdomains`, `uapi Email list_pops`, `/etc/valiases`,
`/etc/userdatadomains`). To support another source panel (Plesk,
DirectAdmin, a bare LAMP box), you only need to reimplement:

- account + real-domain discovery (`source_account_pairs`, and
  `source_extra_domains` for addon domains)
- mailbox discovery (`detect_mailboxes`) and catch-all discovery
  (`detect_catchall`)
- the mailbox password-hash and Maildir *paths* used in
  `phase_migrate_mail` (`lib/migrate-account.sh`)

Everything else — platform detection, database migration, file transfer,
DNS cutover, sanity checks — is already panel-agnostic. The path overrides
at the top of `audit-source.sh` (`SRC_TRUEUSERDOMAINS_FILE` and friends)
also let you point discovery at a fixture tree, which is how the tests
exercise it.
