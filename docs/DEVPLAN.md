# Development Plan: USB Autoinstall (Public)

**Status:** In Progress
**Created:** 2026-04-07
**Updated:** 2026-04-07

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
**Status:** Not Started
**Requires:** both

### Goal

Add Tailscale to the package list and post-install setup so the workstation joins the user's Tailscale network on first boot. Enables remote management from phone via Claude Code web.

### Acceptance Criteria

- [ ] `packages.list` includes `tailscale` package
- [ ] `scripts/download-all-packages.sh` adds Tailscale APT repo and downloads the `.deb` during USB creation
- [ ] `scripts/post-install.sh` enables `tailscaled` service
- [ ] Post-install leaves Tailscale installed but not authenticated (user runs `tailscale up` manually after first boot)
- [ ] [HUMAN] Run `tailscale up` after first boot, authenticate via URL
- [ ] [HUMAN] Verify workstation appears in Tailscale admin console
- [ ] `shellcheck` clean

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
**Status:** Not Started
**Requires:** ai

### Goal

Remove references to Ollama from README.md. Ollama is now a separate project under `~/Projects/ollama/`.

### Acceptance Criteria

- [ ] README.md does not mention "Ollama" in the STORAGE partition description
- [ ] No other stale Ollama references remain in any tracked file
- [ ] `shellcheck` clean (if any scripts touched)

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `README.md` | Modify | Remove Ollama references |

---

## Feature: diagnostics-logs

**Branch:** `fix/diagnostics-logs`
**Depends on:** none
**Status:** Not Started
**Requires:** ai

### Goal

Fix Phase 8 log capture so cloud-init and subiquity logs are saved to the DIAGNOSTICS partition before install completes. Currently only `autoinstall.log` is captured.

### Acceptance Criteria

- [ ] Phase 8 in `user-data` late-commands copies `cloud-init-output.log` to DIAGNOSTICS
- [ ] Phase 8 copies subiquity installer logs (`/var/log/installer/`) to DIAGNOSTICS
- [ ] Logs are copied with `cp` + `|| true` (non-fatal if source missing)
- [ ] `INSTALL-SUMMARY.txt` on DIAGNOSTICS includes timestamps and log file listing
- [ ] `shellcheck` clean

### Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `user-data` | Modify | Expand Phase 8 log capture |

---

## Feature: restic-backup

**Branch:** `feature/restic-backup`
**Depends on:** none
**Status:** Not Started
**Requires:** both

### Goal

Add restic backup support for automated encrypted backups of user data. Packages downloaded for offline install, scripts for backup management.

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
**Status:** Not Started
**Requires:** ai

### Goal

Add a lightweight status dashboard that shows the state of all projects under `~/Projects`. Displays git branch, clean/dirty status, open PRs, CI status, and next DEVPLAN feature. Accessible from the local machine or via Tailscale.

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
**Status:** Not Started
**Requires:** human

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

