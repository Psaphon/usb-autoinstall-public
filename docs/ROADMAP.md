# Roadmap & Issue Tracker

Tracking known issues, planned fixes, and feature work for usb-autoinstall.

---

## Open Issues

### 2. Devtools submodule not initialized
- **Priority:** Low
- **Type:** Bug
- **Description:** `components/devtools/` is empty — git submodule was not initialized after clone. Run `git submodule update --init` to populate. Skipping for current test cycle.
- **Files:** `.gitmodules`, `components/devtools/`

### 3. Implement restic backup packages/scripts
- **Priority:** Medium
- **Type:** Feature
- **Description:** Add restic backup support — packages need to be downloaded for offline install and scripts need to be created for backup management.
- **Files:** TBD

### 4. Diagnostics partition not capturing install logs
- **Priority:** Medium
- **Type:** Bug
- **Description:** The `autoinstall.log` was written to the DIAGNOSTICS partition during install (early-commands and late-commands both log there), but the `cloud-init-output.log` and subiquity installer logs are not being saved to DIAGNOSTICS. The Phase 8 log save step should copy these to the partition before install completes.
- **Files:** `user-data` (late-commands Phase 8)

---

## Completed

### 5. README references Ollama in USB partition layout
- **Resolved:** 2026-05-13
- **Description:** README.md STORAGE partition description no longer mentions "Ollama binary" — now reads "Cloud images, large assets". Ollama is handled by a separate project.
- **Files:** `README.md`

### 1. Remove Ollama from package download script
- **Resolved:** 2026-03-20
- **Description:** Removed `download_ollama()` function and all references from `download-all-packages.sh`. Ollama will be handled by a separate project.
- **Files:** `scripts/download-all-packages.sh`

### 6. Reconcile packages.list with user-data late-commands
- **Resolved:** 2026-03-20
- **Description:** `packages.list` was missing many packages that `user-data` late-commands tried to install, causing all 6 package groups to fail during installation. Added: `lightdm-gtk-greeter-settings`, `wireguard-tools`, `resolvconf`, `python3-flask`, `python3-psutil`, `python3-requests`, `python3-feedparser`, `aide`, `lynis`, `rkhunter`, `chkrootkit`, `debsums`, `build-essential`, `qemu-system-x86`, `qemu-utils`, `cloud-image-utils`.
- **Files:** `packages.list`
