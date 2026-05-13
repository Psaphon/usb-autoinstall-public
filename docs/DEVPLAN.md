# Development Plan: USB Autoinstall (Public)

**Status:** In Progress (transitioning — see note)
**Created:** 2026-04-07
**Updated:** 2026-05-12

> **Transition note (2026-05-12):** A new private repo `hub` (in planning at `~/Projects/NEW-PROJECTS/hub/`) is being built as the persistent headless workstation that will replace this ephemeral installer. While hub is under manual development, this repo continues to ship small Not-Started AI features (currently `fix-ollama-readme` and `diagnostics-logs`). Heavier features (`restic-backup`, `status-dashboard`) and the [HUMAN] cleanup (`devtools-submodule`) are marked Deferred — they will be superseded by hub equivalents or resolved at archival. Patterns from this repo (4-partition USB layout, offline apt, LUKS handling, late-commands phases) are valuable reference for hub's `autoinstall-iso-build` feature.

## Overview

Ephemeral security workstation installer: Ubuntu 25.10 + XFCE, LUKS encryption, fully offline install from USB. 4-partition layout (ESP, DIAGNOSTICS, SECRETS, STORAGE) with modular component deployment. Weekly OS rebuilds from USB, secrets persist on SECRETS partition.

## Constraints

- Shell scripts only — `shellcheck` clean on all `.sh` files
- All scripts idempotent (safe to re-run)
- All scripts use `set -euo pipefail`
- Must work fully offline after USB creation
- Never store secrets in code or commit to git
- Gitflow branching: `main`, `develop`, `feature/*`, `fix/*`
- Conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`

---

## Feature: tailscale-package

**Branch:** `feature/tailscale-package`
**Depends on:** none
**Status:** PR Open
**Requires:** both

### Goal

Add Tailscale to the package list and post-install setup so the workstation joins the user's Tailscale network on first boot. Enables remote management from phone via Claude Code web.

### Acceptance Criteria

- [x] `packages.list` includes `tailscale` package
- [x] `scripts/download-all-packages.sh` adds Tailscale APT repo and downloads the `.deb` during USB creation
- [x] `scripts/post-install.sh` enables `tailscaled` service
- [x] Post-install leaves Tailscale installed but not authenticated (user runs `tailscale up` manually after first boot)
- [ ] [HUMAN] Run `tailscale up` after first boot, authenticate via URL
- [ ] [HUMAN] Verify workstation appears in Tailscale admin console
- [ ] `shellcheck` clean (deferred to CI — shellcheck not installed in dev env)

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `packages.list` | Modify | Add `tailscale` |
| `scripts/download-all-packages.sh` | Modify | Add Tailscale APT repo, download .deb |
| `scripts/post-install.sh` | Modify | Enable tailscaled service |

### Key Decisions

- Install via APT repo (not standalone binary) — integrates with system package management
- Do NOT embed auth key in scripts — user authenticates interactively on first boot
- Auth key could optionally be placed on SECRETS partition for automated joins in the future

### Notes

- Tailscale APT repo: `https://pkgs.tailscale.com/stable/ubuntu`
- GPG key: `https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg`
- The download script already handles external APT repos (Docker, VS Code) — follow that pattern

---

## Feature: fix-ollama-readme

**Branch:** `fix/ollama-readme`
**Depends on:** none
**Status:** Merged
**Requires:** ai

### Goal

Remove references to Ollama from README.md. Ollama is now a separate project under `~/Projects/ollama/`.

### Acceptance Criteria

- [x] README.md does not mention "Ollama" in the STORAGE partition description
- [x] No other stale Ollama references remain in any tracked file
- [x] `shellcheck` clean (if any scripts touched)

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `README.md` | Modify | Remove Ollama references |

---

## Feature: diagnostics-logs

**Branch:** `fix/diagnostics-logs`
**Depends on:** none
**Status:** PR Open
**Requires:** ai

### Goal

Fix Phase 8 log capture so cloud-init and subiquity logs are saved to the DIAGNOSTICS partition before install completes. Currently only `autoinstall.log` is captured.

### Acceptance Criteria

- [x] Phase 8 in `user-data` late-commands copies `cloud-init-output.log` to DIAGNOSTICS
- [x] Phase 8 copies subiquity installer logs (`/var/log/installer/`) to DIAGNOSTICS
- [x] Logs are copied with `cp` + `|| true` (non-fatal if source missing)
- [x] `INSTALL-SUMMARY.txt` on DIAGNOSTICS includes timestamps and log file listing
- [x] `shellcheck` clean

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `user-data` | Modify | Expand Phase 8 log capture |

---

## Feature: restic-backup

**Branch:** `feature/restic-backup`
**Depends on:** none
**Status:** Deferred — superseded by `hub` `data-backup` (private repo `hub`, see `~/Projects/NEW-PROJECTS/hub/DEVPLAN.md`)
**Requires:** both

### Goal

Add restic backup support for automated encrypted backups of user data. Packages downloaded for offline install, scripts for backup management.

> **Deferred 2026-05-12.** The new persistent `hub` workstation (private repo, in planning) will handle backups via its `data-backup` nice-to-have, targeting an internal 2 TB HDD with proper snapshot retention. Adding restic to this ephemeral installer adds complexity for marginal value during the transition window. Revisit only if the ephemeral desktop's lifetime is extended past hub's v1.0.0.

### Acceptance Criteria

- [ ] `packages.list` includes `restic`
- [ ] `scripts/download-all-packages.sh` downloads restic .deb
- [ ] Backup script: `scripts/backup.sh` — backs up `~/Projects` and `~/Documents` to SECRETS partition
- [ ] Restore script: `scripts/restore.sh` — restores from SECRETS partition backup
- [ ] Restic repo initialized on SECRETS partition during post-install
- [ ] [HUMAN] Set restic password (stored on SECRETS partition)
- [ ] [HUMAN] Verify backup and restore cycle works
- [ ] `shellcheck` clean

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `packages.list` | Modify | Add `restic` |
| `scripts/download-all-packages.sh` | Modify | Download restic .deb |
| `scripts/backup.sh` | Create | Automated backup script |
| `scripts/restore.sh` | Create | Restore from backup |
| `scripts/post-install.sh` | Modify | Initialize restic repo |

### Key Decisions

- Backup destination: SECRETS partition (`/media/secrets/backups/`)
- Restic password file on SECRETS partition (never in scripts)
- Daily backup via systemd timer (created in post-install)

---

## Feature: status-dashboard

**Branch:** `feature/status-dashboard`
**Depends on:** none
**Status:** Deferred — superseded by `hub` `dashboard` feature
**Requires:** ai

### Goal

Add a lightweight status dashboard that shows the state of all projects under `~/Projects`. Displays git branch, clean/dirty status, open PRs, CI status, and next DEVPLAN feature. Accessible from the local machine or via Tailscale.

> **Deferred 2026-05-12.** The new `hub` workstation includes a richer Glance + Beszel + FastAPI-collector dashboard reading `dtl workflow` status directly. Shipping the shell-script version here would create two implementations to maintain across the transition. If the ephemeral desktop needs interim visibility, run `dtl workflow list --plan docs/DEVPLAN.md` per-project at the CLI.

### Acceptance Criteria

- [ ] `scripts/project-status.sh` — generates a JSON status report for all git repos under a given directory
- [ ] For each repo: branch, clean/dirty, last commit date, open PR count, CI status (via `gh`)
- [ ] For repos with `docs/DEVPLAN.md`: next unblocked feature name and status
- [ ] HTML output option: `scripts/project-status.sh --html > status.html`
- [ ] HTML is self-contained (inline CSS, no external deps), mobile-friendly
- [ ] Can be served by `python3 -m http.server` for Tailscale access
- [ ] `shellcheck` clean

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/project-status.sh` | Create | Status report generator |

### Key Decisions

- Shell script + `gh` CLI — no Python dependency, works on fresh installs
- JSON intermediate format so other tools can consume it
- HTML is a bonus output mode, not a running server — regenerate on demand or via cron
- Scope: all git repos under the target directory, not just projects with DEVPLANs

### Notes

- Could be run on a cron (e.g., every 15 min) and served as a static HTML page over Tailscale
- Future: integrate with morning-brief dashboard for a unified view

---

## Feature: devtools-submodule

**Branch:** `fix/devtools-submodule`
**Depends on:** none
**Status:** Deferred — resolve as part of repo archival
**Requires:** human

> **Deferred 2026-05-12.** This is a cleanup item; the cleanest moment to resolve it is when this repo is finally archived in favor of `hub`. Until then it's harmless cruft.

### Goal

Fix the empty `components/devtools/` submodule. Either initialize it properly or remove it if devtools is no longer bundled as a submodule.

### Acceptance Criteria

- [ ] [HUMAN] Decide: keep submodule or remove it
- [ ] If keep: `git submodule update --init` works, README documents the step
- [ ] If remove: `.gitmodules` cleaned up, `components/devtools/` removed

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `.gitmodules` | Modify | Fix or remove submodule reference |

