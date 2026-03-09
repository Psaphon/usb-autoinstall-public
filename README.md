# USB Autoinstall - Ephemeral Security Workstation

**Version:** 3.2.1-dev
**Target OS:** Ubuntu 25.10 Server + XFCE Desktop
**Boot Mode:** UEFI (GPT)

Automated USB-based installation system for creating a hardened, ephemeral security workstation with XFCE desktop environment. Designed for weekly OS reinstalls with full disk encryption.

---

## Features

- **15 Minute Deployment** - From USB boot to fully configured desktop
- **LUKS Full Disk Encryption** - Set passphrase during install
- **XFCE Desktop** - Lightweight GUI with auto-login
- **Security Hardening** - 30+ kernel parameters (CIS benchmarks)
- **Offline Installation** - Pre-downloaded packages on USB
- **Package Integrity** - SHA256 verification before installation
- **VPN Ready** - WireGuard with killswitch scripts
- **Persistent Secrets** - SECRETS partition persists VPN and wifi configs across rebuilds

### What Gets Installed

| Component | Description |
|-----------|-------------|
| XFCE Desktop | Lightweight desktop environment with LightDM |
| Monitoring Dashboard | Web UI at http://localhost:5000 (weather, news) |
| VPN Killswitch | iptables-based, active at boot before networking |
| VPN Scripts | WireGuard management (vpn-up, vpn-down, killswitch) |
| Dev Tools | Multi-stack project scaffolder with devcontainer support |
| VS Code | Code editor (offline .deb install) |
| Firefox | Mozilla .deb (not snap stub), works offline |
| Security Monitor | Checks VPN, DNS leaks, IPv6 leaks every 5 min |
| Security Tools | fail2ban, aide, lynis, rkhunter, debsums |

---

## Quick Start

### Prerequisites

- Ubuntu 25.10 Server ISO ([download](https://releases.ubuntu.com/questing/))
- USB drive (32GB+ recommended)
- Linux system with: `sgdisk`, `mkfs.vfat`, `grub-install`, `xorriso`, `rsync`, `dpkg-scanpackages`

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt install gdisk dosfstools grub-efi-amd64-bin xorriso rsync dpkg-dev
```

### 1. Set Up VPN (WireGuard)

Prepare your WireGuard config so VPN works immediately after install.

**Getting WireGuard credentials from your VPN provider:**

| Provider | How to get config |
|----------|------------------|
| ProtonVPN | Dashboard > Downloads > WireGuard configuration |
| Mullvad | Account > WireGuard configuration |
| IVPN | Account > WireGuard > Generate key |
| Self-hosted | `wg genkey` / `wg pubkey` on your server |

Your `wg0.conf` should look like:
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

> **Note:** `wg0.conf` is gitignored and will never be committed. The template file (`wg0.conf.template`) contains only placeholders.

### 2. Download Packages

```bash
# Download all packages for offline install (~1.8GB)
sudo ./scripts/download-all-packages.sh
```

### 3. Create Bootable USB

```bash
sudo ./scripts/create-bootable-usb.sh \
    /path/to/ubuntu-25.10-live-server-amd64.iso \
    /dev/sdX \
    .
```

### 4. Boot and Install

1. Boot target machine from USB (UEFI mode, Secure Boot disabled)
2. Storage screen appears — select target drive and **set your LUKS passphrase**
3. Installation runs automatically (~15 minutes)
4. System reboots into XFCE desktop

### 5. Post-Installation

```bash
# Set up VPN (if not auto-configured)
sudo nano /etc/wireguard/wg0.conf
sudo vpn-up

# Change default password (currently: "password")
passwd

# Access security dashboard
xdg-open http://localhost:5000
```

---

## Directory Structure

```
usb-autoinstall/
├── README.md                 # This file
├── user-data                 # Cloud-init autoinstall config
├── meta-data                 # Cloud-init metadata
│
├── docs/                     # Documentation
│   └── USB-CREATION.md      # Detailed USB creation guide
│
├── scripts/
│   ├── create-bootable-usb.sh    # USB creation (GPT/UEFI)
│   ├── download-all-packages.sh  # Download packages for offline install
│   ├── manage-secrets.sh         # SECRETS partition management
│   ├── post-install.sh           # System deployment (runs during install)
│   └── verify-packages.sh        # SHA256 package verification
│
├── packages/                 # Pre-downloaded .deb files (gitignored)
│   └── SHA256SUMS           # Package checksums (tracked)
│
├── files/                    # Core system files deployed to installed system
│   └── configs/             # System configs (sysctl hardening) → /etc/
│
└── components/              # Modular components (each with install.sh)
    └── devtools/            # Dev environment launcher (submodule)
```

---

## USB Partition Layout

```
Partition 1: UEFI_BOOT    (10GB, FAT32)    — OS installer + autoinstall files
Partition 2: DIAGNOSTICS   (1GB, FAT32)    — Installation logs
Partition 3: SECRETS       (5GB, ext4)     — VPN configs, wifi, SSH keys (preserved across rebuilds)
Partition 4: STORAGE       (remaining, ext4) — Ollama binary, cloud images, large assets
```

### SECRETS Partition Setup (One-Time)

```bash
# 1. Create the SECRETS partition (after creating the bootable USB)
sudo ./scripts/manage-secrets.sh init /dev/sdX

# 2. Add your WireGuard config
sudo ./scripts/manage-secrets.sh add-wireguard /dev/sdX ~/wg0.conf

# 3. Add wifi connection (optional)
sudo ./scripts/manage-secrets.sh add-wifi /dev/sdX MyNetwork mypassword
```

The SECRETS partition is preserved when you rebuild the USB.

### Weekly Reinstall

```
1. Rebuild USB (SECRETS preserved)
2. Boot from USB, set LUKS passphrase at storage screen (~15 min)
```

### Managing Secrets

```bash
sudo ./scripts/manage-secrets.sh list /dev/sdX        # Show contents
sudo ./scripts/manage-secrets.sh open /dev/sdX        # Mount for access
sudo ./scripts/manage-secrets.sh close                # Unmount
```

---

## Security Model

### Ephemeral Workstation

This system is designed for **weekly OS reinstalls**:

```
Week N:
├── Boot from USB (~15 min)
├── Configure VPN (~2 min)
├── Work normally (Docker containers, external storage)
└── End of week: backup data

Week N+1:
├── Boot from USB (fresh OS)
└── No accumulated bloat, no persistent malware
```

### Hardening Applied

- **LUKS Full Disk Encryption**
- **30+ Kernel Parameters** (sysctl hardening)
- **UFW Firewall** (deny incoming by default)
- **fail2ban** (intrusion detection)
- **VPN Killswitch** (iptables-based network lockdown)
- **Automatic Security Updates** (unattended-upgrades)

### Package Verification

Three-layer verification:
1. **Download:** APT verifies GPG signatures
2. **Pre-install:** `verify-packages.sh` checks SHA256 sums
3. **Post-install:** Monthly integrity checks

---

## USB Boot Requirements

This creates a **UEFI-only** bootable USB with GPT partition table.

**BIOS Settings:**
- Enable UEFI boot mode
- Disable Secure Boot (or add custom keys)
- Set USB as boot priority

**Not compatible with:**
- Legacy BIOS-only systems
- Systems requiring Secure Boot without custom keys

---

## Customization

### Edit `user-data` to change:
- Hostname
- Username/password
- Package list (in the `late-commands` apt-get install section)
- Timezone
- Partition layout

### Add packages:
1. Edit the `apt-get install` list in the `late-commands` section of `user-data`
2. Run `./scripts/download-all-packages.sh`
3. Rebuild USB

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| USB not appearing in boot menu | Disable Secure Boot, enable UEFI mode |
| Autoinstall doesn't trigger | Check GRUB config has `autoinstall` parameter |
| Package verification fails | Re-run `download-all-packages.sh` |
| Desktop doesn't start | Check `journalctl -u lightdm` |

See [docs/USB-CREATION.md](docs/USB-CREATION.md) for detailed troubleshooting.

---

## Documentation

- [USB Creation Guide](docs/USB-CREATION.md) — Detailed creation steps and troubleshooting
- [Dev Tools](components/devtools/README.md) — Project scaffolder usage and design

---

## License

MIT License - See [LICENSE](LICENSE) for details.

---

## Contributing

### Workflow

1. Fork the repository
2. Create a feature branch
3. **Test all changes in a VM before hardware** (QEMU/KVM or VirtualBox with 4GB RAM, 25GB disk)
4. Commit with clear messages (see format below)
5. Submit a pull request

### Code Standards

- **Shell scripts:** Lint with `shellcheck` before committing
- **Python:** Follow PEP 8
- **YAML (`user-data`):** Validate syntax — malformed autoinstall configs fail silently
- **Security:** Never commit secrets (`wg0.conf`, `*.key`, `*.pem`, `.env` are gitignored)
- **Documentation:** Update README and CHANGELOG when adding features

### Commit Messages

```
<type>: <description>

[optional body]
```

Types: `feat` (new feature), `fix` (bug fix), `docs` (documentation), `refactor` (restructuring), `test` (adding tests), `chore` (maintenance)

### Verify ISO Integrity

When downloading a new Ubuntu ISO, always verify checksums:

```bash
cd /path/to/iso/
wget https://releases.ubuntu.com/questing/SHA256SUMS
sha256sum -c SHA256SUMS 2>&1 | grep ubuntu-25.10-live-server-amd64.iso
# Expected: ubuntu-25.10-live-server-amd64.iso: OK
```

---

## Version History

- **3.2.0** (2026-03-05)
  - Full code review and overhaul of all security scripts, dashboard, dev tools
  - Firefox: real Mozilla .deb (replaced broken snap stub)
  - VPN killswitch: DNS leak prevention, correct rule ordering
  - Dashboard: Flask 3.x fixes, VPN status detection
  - Dev tools: ground-up rewrite — multi-stack scaffolder
  - Wifi auto-connect from SECRETS partition
  - See [GitHub Release](https://github.com/your-username/usb-autoinstall/releases/tag/v3.2.0)

- **3.0.0** (2026-02-11)
  - SECRETS partition for persistent configs across rebuilds
  - 4-partition USB layout (ESP + DIAG + SECRETS + STORAGE)

- **2.1.0** (2026-02-08) — First successful hardware install

- **1.0.0** (2025-10-26) — Initial release

Full history: [GitHub Releases](https://github.com/your-username/usb-autoinstall/releases)
