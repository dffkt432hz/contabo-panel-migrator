# Supported scenarios

Contabo's marketplace lets you provision a fresh VPS with several
pre-built app images. This toolkit's automated path targets the
**cPanel/WHM -> Webmin + LAMP (Virtualmin)** move specifically, since
that's the case with no existing native transfer tool. The table below
covers every combination you might be starting from or moving to.

| Source panel | Target image                | Automated by this toolkit? | Notes |
|---|---|---|---|
| cPanel/WHM | **Webmin + LAMP** (Virtualmin) | **Yes — full pipeline** | The primary use case. `virtual-server` (Virtualmin) must be present on the target; the wizard checks for it and tells you if it isn't. |
| cPanel/WHM | Bare **Webmin** (no LAMP/virtual-server module) | Partially | File/DB/mail transfer and audits run fine. Per-domain vhost + PHP-pool + catch-all setup assume Virtualmin's `virtualmin` CLI and are skipped with a warning if it's absent — either install the `virtual-server` module first, or configure each vhost by hand after the file/DB/mail transfer. |
| cPanel/WHM | **cPanel/WHM** | No — use WHM's native tool instead | WHM's built-in **Transfer Tools -> Copy an Account From Another Server** already does exactly this, directly cPanel-to-cPanel, more completely than a third-party script reasonably can (it understands cPanel's own account-package format natively). The wizard detects this choice and points you there instead of re-implementing it. |
| Any other source (Plesk, DirectAdmin, bare LAMP) | Webmin + LAMP (Virtualmin) | Partially | Platform detection, file transfer, DB migration, DNS cutover, and sanity checks are panel-agnostic and work as-is. Account/domain/mailbox *discovery* (`lib/audit-source.sh`) currently assumes cPanel's own account layout and needs a small adapter for your source panel — see "Extending to other source panels" in `docs/ARCHITECTURE.md`. |

## Target OS

Virtualmin/Webmin installs cleanly on any of Contabo's Linux app-image
options — AlmaLinux 9/10, Rocky Linux 8/9, Ubuntu 22.04/24.04, and Debian.
The wizard's OS question is informational only (it doesn't change any
command run against the target); pick whichever the rest of your
infrastructure already standardizes on. Windows Server images are out of
scope — this toolkit assumes a POSIX shell and SSH on both ends.

## What "fully automated" actually means

Even in the fully-automated cPanel -> Virtualmin path, four things are
explicitly *not* automated, on purpose:

- **Addon and parked domains.** The pipeline migrates each account's *main*
  domain. The source audit lists any addon/parked domains it finds on each
  account (so nothing is a surprise), but they need their own run.

- **DNS records other than A/www/SPF/DKIM** (MX, NS, SOA, DMARC, and any
  site-verification TXT records) are left untouched. Touching MX/NS
  automatically is exactly the kind of "helpful" automation that breaks a
  domain in a way that's hard to notice until mail stops arriving.
- **The decision to actually cut DNS over** happens per domain, once you've
  reviewed that account's audit and sanity-check output — the wizard never
  cuts over a domain you haven't explicitly confirmed.
- **Decommissioning the source server** is never done by this toolkit.
  That's a one-way action with real consequences and belongs entirely to
  a human, after a real monitoring window (recommended: 24-48h of both
  servers running in parallel, source kept live as a fallback).
