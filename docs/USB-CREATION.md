# USB Autoinstall Creation Guide

Complete guide for creating a bootable USB stick with automated Ubuntu installation.

**Version:** 3.0.0
**Target OS:** Ubuntu 25.10 (Questing Quokka)
**Total Time:** ~10 minutes to create USB, ~15 minutes automated install

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Detailed Steps](#detailed-steps)
4. [Package Management](#package-management)
5. [Installation Process](#installation-process)
6. [Post-Install Configuration](#post-install-configuration)
7. [Testing](#testing)
8. [Troubleshooting](#troubleshooting)
9. [Advanced Topics](#advanced-topics)
10. [Security Considerations](#security-considerations)

---

## Prerequisites

### Hardware
- USB stick (32GB+ recommended)
- Quality USB stick (avoid cheap/unreliable brands — corrupted packages will abort the install)
- Target machine with UEFI boot support

### Software
- Ubuntu 25.10 Server ISO ([download](https://releases.ubuntu.com/questing/))
- This repository cloned locally
- Linux system with: `sgdisk`, `mkfs.vfat`, `grub-install`, `xorriso`, `rsync`, `dpkg-scanpackages`

```bash
# Install build dependencies (Ubuntu/Debian)
sudo apt install gdisk dosfstools grub-efi-amd64-bin xorriso rsync dpkg-dev
```

### Skills
- Basic Linux command line
- Ability to identify USB device names (`lsblk`)

---

## Quick Start

```bash
cd /path/to/usb-autoinstall

# 1. Download all packages for offline install (~1.8GB)
sudo ./scripts/download-all-packages.sh

# 2. Create bootable USB (replace /dev/sdX and ISO path)
sudo ./scripts/create-bootable-usb.sh \
    /path/to/ubuntu-25.10-live-server-amd64.iso \
    /dev/sdX \
    .

# 3. Boot target machine from USB (UEFI, Secure Boot disabled)
# 4. Set LUKS passphrase at storage screen
# 5. Wait ~15 minutes — fully automated
# 6. Login, configure VPN, change password
```

---

## Detailed Steps

### Step 1: Download Ubuntu ISO

```bash
wget https://releases.ubuntu.com/questing/ubuntu-25.10-live-server-amd64.iso

# Verify checksum (important!)
wget https://releases.ubuntu.com/questing/SHA256SUMS
sha256sum -c SHA256SUMS 2>&1 | grep ubuntu-25.10-live-server-amd64.iso
# Expected: ubuntu-25.10-live-server-amd64.iso: OK
```

### Step 2: Set Up VPN Config (Optional)

If you want VPN to work immediately after install, add your WireGuard config to the SECRETS partition after creating the USB (see Step 4b).

### Step 3: Download Packages

```bash
# Downloads all packages + dependencies for fully offline install (~1.8GB, ~2,279 packages)
sudo ./scripts/download-all-packages.sh
```

This script:
- Downloads all packages listed in `user-data` late-commands
- Recursively resolves all dependencies
- Downloads Docker packages from the Docker repository
- Downloads VS Code from Microsoft
- Generates `SHA256SUMS` for integrity verification
- Generates APT repository index files (`Packages`, `Packages.gz`)

### Step 4: Create Bootable USB

**WARNING: This will ERASE the target USB drive!**

```bash
# Identify your USB device
lsblk
# Look for your USB stick (e.g., /dev/sdb) — DO NOT use your system drive

sudo ./scripts/create-bootable-usb.sh \
    /path/to/ubuntu-25.10-live-server-amd64.iso \
    /dev/sdX \
    .
```

The script handles everything automatically:
- Creates GPT partition table with EFI System (4GB) and DIAGNOSTICS (1GB) partitions
- **Preserves existing SECRETS partition** (partition 3) if present
- Installs GRUB for UEFI boot
- Copies ISO contents, autoinstall files, and packages
- Modifies GRUB boot parameters (`autoinstall ds=nocloud\;s=/cdrom/usb-autoinstall/`)
- Pre-generates APT repository index files
- Verifies the result

### Step 4b: Set Up SECRETS Partition (One-Time)

After creating the bootable USB, add a SECRETS partition for persistent VPN and wifi configs:

```bash
# Create SECRETS partition (plain ext4)
sudo ./scripts/manage-secrets.sh init /dev/sdX

# Add your WireGuard config
sudo ./scripts/manage-secrets.sh add-wireguard /dev/sdX ~/wg0.conf

# Add wifi connection (optional)
sudo ./scripts/manage-secrets.sh add-wifi /dev/sdX MyNetwork mypassword
```

The SECRETS partition is preserved when you rebuild the USB.

```
Partition 1: UEFI_BOOT    (10GB, FAT32)    — Rebuilt each time
Partition 2: DIAGNOSTICS   (1GB, FAT32)     — Rebuilt each time
Partition 3: SECRETS       (5GB, ext4)      — Preserved across rebuilds
Partition 4: STORAGE       (remaining, ext4) — Large assets (Ollama, cloud images)
```

### Step 5: Boot and Install

1. Insert USB into target machine
2. Enter BIOS/UEFI settings:
   - Enable UEFI boot mode
   - Disable Secure Boot
   - Set USB as first boot device
3. Boot from USB
4. **Storage screen appears** — select target drive and **set your LUKS passphrase**
5. Installation runs automatically (~15 minutes)
6. System reboots into XFCE desktop (auto-login)

---

## Package Management

### Why Pre-Download Packages?

1. **Speed**: Install in ~3 min vs 10-15 min download
2. **Security**: Verify packages once, use many times
3. **Reproducibility**: Same versions every install
4. **Offline**: No internet needed during install
5. **Air-gap**: Compatible with ephemeral security model

### Package Integrity Verification

Packages are verified automatically during installation via `verify-packages.sh`:

1. `SHA256SUMS` file must exist
2. All `.deb` packages must match their checksums
3. **If verification fails, installation aborts** — no tampered packages can be installed

### Adding Custom Packages

1. Add the package name to the `apt-get install` list in the `late-commands` section of `user-data`
2. Re-run the download script:
   ```bash
   sudo ./scripts/download-all-packages.sh
   ```
3. Rebuild USB

### Updating Packages

```bash
# Re-run the download script (fetches latest versions)
sudo ./scripts/download-all-packages.sh

# Rebuild USB
sudo ./scripts/create-bootable-usb.sh /path/to/iso /dev/sdX .
```

---

## Installation Process

### Timeline

```
00:00 - Boot from USB
00:01 - Ubuntu installer starts, autoinstall detected
00:02 - Early-commands run (package verification, apt repo setup, logging)
00:03 - Storage screen appears (user sets LUKS passphrase)
00:05 - Base system installation begins (from ISO)
00:08 - Late-commands run:
         - Local apt repo configured in /target
         - chroot package installation (~2,279 packages)
         - System hardening applied
         - Services enabled
         - Post-install script runs
00:14 - Diagnostic summary written to DIAGNOSTICS partition
00:15 - Reboot into XFCE desktop
```

### User Interaction Required

1. **LUKS Passphrase** (~minute 3) — set your disk encryption password
2. **That's it** — everything else is automated

### What Gets Installed

**Desktop Environment:**
- XFCE desktop with LightDM (auto-login after LUKS unlock)
- Firefox, VS Code, Tilix terminal
- Desktop notifications for security alerts

**Services:**
- Docker (container runtime)
- UFW (firewall, deny incoming by default)
- fail2ban (intrusion detection)
- Dashboard (monitoring web UI at localhost:5000)
- Security monitor timer (periodic checks)

**Security:**
- 30+ kernel hardening parameters (sysctl)
- SSH hardening (no root login, key-based auth)
- Unattended security upgrades
- VPN killswitch scripts (WireGuard)

---

## Post-Install Configuration

### Step 1: Change Default Password

```bash
passwd
```

The default password is `password` — change it immediately.

### Step 2: Add WireGuard Config

```bash
sudo nano /etc/wireguard/wg0.conf
```

Add your VPN provider config:
```ini
[Interface]
PrivateKey = <your-private-key>
Address = 10.x.x.x/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = <server-public-key>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = <server-ip>:51820
```

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo vpn-up
```

### Step 3: Access Dashboard

Open Firefox and navigate to `http://localhost:5000`, or use the desktop launcher:
**Applications > System > Baseline Security Dashboard**

### Step 4: Configure Git (Optional)

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

---

## Testing

### Test in VM First (Recommended)

```bash
# QEMU example
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
    -bios /usr/share/ovmf/OVMF.fd \
    -drive file=test-disk.qcow2,format=qcow2,if=virtio \
    -drive file=/dev/sdX,format=raw,if=none,id=usb \
    -device usb-storage,drive=usb \
    -boot menu=on
```

Or use VirtualBox/VMware with:
- 2+ CPU cores
- 4GB+ RAM (desktop needs more than server)
- 25GB+ disk
- EFI boot enabled

### Post-Install Verification Checklist

```bash
# Services
systemctl status docker
systemctl status ufw
systemctl status fail2ban
systemctl status lightdm

# Dashboard
curl -s http://localhost:5000/api/status

# Security hardening
sysctl net.ipv4.conf.all.accept_source_route
# Expected: 0

# VPN scripts available
which vpn-up vpn-down killswitch

# Files deployed
ls /opt/dashboard/
ls /usr/local/bin/ | grep -E "(vpn|security|killswitch)"

# Desktop
# - XFCE loaded, auto-login worked
# - Dashboard launcher in Applications menu
# - Desktop notification test: security-notify.sh info "Test"
```

---

## Troubleshooting

### USB Won't Boot

| Check | Fix |
|-------|-----|
| BIOS doesn't see USB | Enable UEFI mode, disable Secure Boot |
| USB not bootable | Verify GPT table: `sudo fdisk -l /dev/sdX` (should show `Disklabel type: gpt`, partition 1 = `EFI System`) |
| Wrong boot order | Set USB as first boot device in BIOS |
| Legacy BIOS only | This USB is UEFI-only — legacy BIOS systems are not supported |

### Autoinstall Not Triggering (Language Selection Appears)

The GRUB boot parameters are missing or malformed.

```bash
# Verify GRUB config on USB
sudo mount /dev/sdX1 /mnt
grep vmlinuz /mnt/boot/grub/grub.cfg
# Must contain: ds=nocloud\;s=/cdrom/usb-autoinstall/
sudo umount /mnt
```

Common cause: semicolon not escaped. GRUB treats `;` as a command separator — it must be `\;`.

### Install Fails (Check Diagnostic Logs)

The DIAGNOSTICS partition captures logs on both success and failure:

```bash
# Mount DIAGNOSTICS partition (partition 2 on USB)
sudo mount /dev/sdX2 /mnt

# Success logs
cat /mnt/autoinstall.log           # Timestamped install trace
cat /mnt/INSTALL-SUMMARY.txt       # Quick summary

# Failure logs (only present if install failed)
cat /mnt/ERROR.log                 # Detailed error capture

# Full logs (copied on failure)
ls /mnt/installer/                 # Installer logs
cat /mnt/cloud-init-output.log     # Cloud-init output

sudo umount /mnt
```

Key markers in `autoinstall.log`:
- `[EARLY]` — pre-install phase (package verification, apt setup)
- `[LATE]` — post-install phase (package install, config, services)
- `[ERROR]` — install failure diagnostics
- Missing `[LATE]` entries = install failed during base system or storage phase

### Package Installation Fails

| Symptom | Cause | Fix |
|---------|-------|-----|
| `xfce4` not found | Target apt has no local repo source | Ensure late-commands write `local-usb.list` (check `user-data`) |
| Checksum mismatch | Corrupted USB or packages | Re-run `download-all-packages.sh`, rebuild USB |
| Dependency errors | Incomplete package set | Re-run `download-all-packages.sh` (resolves deps recursively) |

### Services Not Starting

```bash
# Check specific service
sudo systemctl status dashboard
sudo journalctl -u dashboard -n 50

# Check if files were deployed
ls -la /opt/dashboard/
ls -la /etc/systemd/system/dashboard.service
```

### Stale LUKS/LVM on Target Drive

If the target drive has partitions from a prior install attempt, the storage phase may fail. Wipe it first:

```bash
# WARNING: Destroys all data on the target drive
sudo wipefs -a /dev/nvmeXn1
sudo sgdisk --zap-all /dev/nvmeXn1
```

---

## Advanced Topics

### Customizing the Installation

Edit `user-data` to change:
- **Hostname:** `hostname:` field in `identity` section
- **Username/password:** `identity` section (generate hash with `openssl passwd -6`)
- **Packages:** `apt-get install` list in the `late-commands` section
- **Timezone:** `timezone:` field
- **Partition layout:** `storage:` section

After modifications, re-run `download-all-packages.sh` and rebuild USB.

### Multiple Configurations

```bash
# Clone the repo for a variant
cp -r usb-autoinstall usb-autoinstall-variant

# Modify user-data
nano usb-autoinstall-variant/user-data

# Build separate USB
sudo ./usb-autoinstall-variant/scripts/create-bootable-usb.sh \
    /path/to/iso /dev/sdX usb-autoinstall-variant
```

### Debugging a Failed Installation

**Enable verbose boot logging** — edit GRUB on the USB:

```bash
sudo mount /dev/sdX1 /mnt
# In grub.cfg, replace "quiet splash" with "debug"
sudo nano /mnt/boot/grub/grub.cfg
sudo umount /mnt
```

**Access console during install** — press `Alt+F2` to switch to a shell:

```bash
# View live cloud-init output
tail -f /var/log/cloud-init-output.log

# View subiquity installer logs
tail -f /var/log/installer/subiquity-server-debug.log

# Check apt status in target chroot
cat /target/etc/apt/sources.list.d/local-usb.list
chroot /target apt-cache policy xfce4
```

---

## Security Considerations

### Package Trust

Three-layer verification:

1. **Download time:** APT verifies GPG signatures from official repositories
2. **Pre-install:** `verify-packages.sh` checks SHA256 checksums of all `.deb` files
3. **Post-install:** Monthly integrity checks via `debsums` (systemd timer)

### LUKS Encryption

- Full disk encryption is configured during install
- The storage screen prompts for your passphrase — choose a strong one (20+ characters)
- **There is no recovery if the passphrase is forgotten**
- The passphrase is required at every boot (before XFCE auto-login)

### Default Credentials

- Default user password is `password` (SHA-512 hashed in `user-data`)
- **Change immediately after first login** with `passwd`
- Or generate a custom hash before building USB: `openssl passwd -6 "your-password"`

### Secure Boot

- Secure Boot must be disabled for this custom USB
- Can be re-enabled after installation if desired
- Future enhancement: sign GRUB/kernel with custom MOK keys

---

## Quick Reference

**Create USB:**
```bash
sudo ./scripts/download-all-packages.sh
sudo ./scripts/create-bootable-usb.sh /path/to/iso /dev/sdX .
```

**Post-Install:**
```bash
passwd                                  # Change default password
sudo nano /etc/wireguard/wg0.conf      # Add VPN config
sudo chmod 600 /etc/wireguard/wg0.conf
sudo vpn-up                            # Connect VPN
firefox http://localhost:5000           # Access dashboard
```

**Weekly Reinstall:**
1. Rebuild USB (SECRETS preserved)
2. Boot USB (~15 min automated), set LUKS passphrase

**Check Diagnostic Logs:**
```bash
sudo mount /dev/sdX2 /mnt && cat /mnt/autoinstall.log && sudo umount /mnt
```
