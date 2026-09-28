# Security policy

## Reporting a vulnerability

Please report security problems **privately** using GitHub's
[private vulnerability reporting](https://github.com/dffkt432hz/contabo-panel-migrator/security/advisories/new)
for this repository, not in a public issue.

**Never paste real credentials, IP addresses, private keys, API secrets or
mailbox contents into an issue or pull request** — not even to show a bug.
Redact them first. If you accidentally post one, revoke/rotate it
immediately; deleting the post does not un-leak it.

## What this toolkit does with secrets

- **Nothing sensitive is stored in the repository.** `config/config.example.env`
  is entirely blank; every real `config/*.env` file, `audit-*/` run directory,
  key, and log is git-ignored. The offline test suite fails if a private key,
  API token, or a non-documentation IP address ever appears in a tracked file.
- **Contabo API credentials** are prompted for (the secret and password are
  read without echo) or read from your git-ignored `config/config.env`.
  If you use `config.env`, restrict it (`chmod 600 config/config.env`) and
  delete it when the migration is finished.
- **Application database passwords** are read from each site's own config file
  only to recreate the database user on the target. The audit step never
  prints or records them.
- **Passwords generated for new domains** are written to
  `audit-<timestamp>/generated-passwords.tsv` with mode `600` inside a `700`
  directory. Move them to a password manager and delete the directory when
  you are done.
- **Secrets on command lines.** Database passwords are sent to `mysql` on
  stdin and to the connection test through `MYSQL_PWD`, so they are not part
  of any process argument list. Two things still are, briefly, for the
  moment the command runs: a mailbox's password *hash* (as an argument to
  `virtualmin create-user --encpass`) and the Contabo credentials (as
  `curl` arguments on the machine running the wizard). Run the wizard on a
  machine, and against servers, where no untrusted user can read the
  process list.
- **SSH.** Host keys are accepted on first use (`StrictHostKeyChecking=accept-new`)
  and every remote command is fully scripted. File transfers are relayed
  through the machine running the wizard, so the source and target servers
  never need SSH trust in each other.

## If you committed a secret by accident

1. **Revoke or rotate it first.** Assume it is already compromised.
2. Then remove it from the repository and its history
   (`git filter-repo`, or delete and recreate the repository if it is new).
   Removing it from history does not make a previously-public secret safe.
