#!/bin/bash
#===============================================================================
# Native GPT UEFI USB Autoinstall Creation Script
#===============================================================================
# Description: Creates a proper GPT-partitioned UEFI bootable USB with autoinstall
# Version: 3.0.0
# Author: Ephemeral Security Workstation Project
#
# This script creates a MODERN UEFI bootable USB (not hybrid ISO):
#   1. GPT partition table (modern UEFI standard)
#   2. FAT32 EFI System Partition with Ubuntu + autoinstall files
#   3. Optional diagnostics partition for logs/debugging
#   4. GRUB bootloader installed directly to ESP
#   5. Optimized for modern UEFI systems
#
# Advantages over hybrid ISO approach:
#   ✓ Recognized by picky UEFI firmware (MSI, ASUS, etc.)
#   ✓ Proper GPT partition table
#   ✓ Writable filesystem for debugging
#   ✓ Cleaner, more reliable boot process
#
# Usage:
#   sudo ./create-bootable-usb-gpt.sh <ubuntu-iso> <usb-device> [autoinstall-dir]
#
# Example:
#   sudo ./create-bootable-usb-gpt.sh ubuntu-25.10-live-server-amd64.iso /dev/sdc
#   sudo ./create-bootable-usb-gpt.sh ubuntu-25.10-live-server-amd64.iso /dev/sdc /mnt/sda2/usb-autoinstall
#===============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

#===============================================================================
# CONFIGURATION
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="/tmp/ubuntu-autoinstall-gpt-$$"
LOG_FILE="/tmp/usb-creation-gpt-$$.log"

# Partition configuration (4-partition layout)
ESP_SIZE="10240"     # 10GB for EFI System Partition (ISO ~2GB + core .deb packages ~2GB + headroom)
DIAG_SIZE="1024"     # 1GB for Diagnostics partition (logs/debugging)
SECRETS_SIZE="5120"  # 5GB for SECRETS partition (keys, configs, wifi — persists across rebuilds)
                     # Partition 4 (STORAGE) gets all remaining space
ESP_LABEL="UEFI_BOOT"
DIAG_LABEL="DIAGNOSTICS"
SECRETS_LABEL="SECRETS"
STORAGE_LABEL="STORAGE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#===============================================================================
# LOGGING & OUTPUT
#===============================================================================

log() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $*${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

#===============================================================================
# HELPERS
#===============================================================================

# Get partition device path for a given base device and partition number
get_part() {
    local device="$1"
    local num="$2"
    if [[ "$device" == *"nvme"* ]] || [[ "$device" == *"mmcblk"* ]]; then
        echo "${device}p${num}"
    else
        echo "${device}${num}"
    fi
}

get_secrets_part() { get_part "$1" 3; }
get_storage_part() { get_part "$1" 4; }

#===============================================================================
# CLEANUP
#===============================================================================

cleanup() {
    log "Cleaning up temporary files..."

    # Unmount any mounted partitions from work directory
    for mount in "$WORK_DIR/esp" "$WORK_DIR/diag" "$WORK_DIR/storage"; do
        if mountpoint -q "$mount" 2>/dev/null; then
            umount "$mount" || true
        fi
    done

    # Remove work directory
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT INT TERM

#===============================================================================
# VALIDATION
#===============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        error "Usage: sudo $0 <ubuntu-iso> <usb-device> [autoinstall-dir]"
        exit 1
    fi
}

check_requirements() {
    log "Checking requirements..."

    local missing=()

    # Check required commands
    for cmd in sgdisk mkfs.vfat grub-install xorriso rsync lsblk dpkg-scanpackages; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required commands: ${missing[*]}"
        error "Install with: sudo apt-get install gdisk dosfstools grub-efi-amd64-bin xorriso rsync dpkg-dev"
        exit 1
    fi

    log "✓ All requirements met"
}

validate_iso() {
    local iso="$1"

    if [ ! -f "$iso" ]; then
        error "ISO file not found: $iso"
        exit 1
    fi

    if ! file "$iso" | grep -q "ISO 9660"; then
        error "Invalid ISO file: $iso"
        exit 1
    fi

    log "✓ ISO file valid: $iso"
}

validate_usb() {
    local device="$1"

    if [ ! -b "$device" ]; then
        error "USB device not found: $device"
        error "Available devices:"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep disk
        exit 1
    fi

    # Check if device is mounted
    if mount | grep -q "^$device"; then
        warn "Device $device has mounted partitions"
        warn "Will unmount before proceeding"
    fi

    # Get device info
    local size
    size=$(lsblk -b -d -n -o SIZE "$device")
    local size_gb=$((size / 1024 / 1024 / 1024))

    if [ "$size_gb" -lt 8 ]; then
        error "USB device too small (${size_gb}GB). Need at least 8GB"
        exit 1
    fi

    log "✓ USB device valid: $device (${size_gb}GB)"
}

validate_autoinstall() {
    local autoinstall_dir="$1"

    if [ ! -d "$autoinstall_dir" ]; then
        error "Autoinstall directory not found: $autoinstall_dir"
        exit 1
    fi

    # Check required files
    local required_files=("user-data" "meta-data")
    for file in "${required_files[@]}"; do
        if [ ! -f "$autoinstall_dir/$file" ]; then
            error "Missing required file: $autoinstall_dir/$file"
            exit 1
        fi
    done

    log "✓ Autoinstall directory valid: $autoinstall_dir"
}

confirm_action() {
    local device="$1"
    local has_secrets="$2"
    local secrets_action="$3"

    echo ""
    if [ "$has_secrets" = "true" ]; then
        warn "⚠️  WARNING: Partitions 1+2 on $device will be ERASED ⚠️"
        log "SECRETS partition (partition 3) will be PRESERVED"
    else
        warn "⚠️  WARNING: This will ERASE all data on $device ⚠️"
    fi
    echo ""
    echo "Device information:"
    lsblk -o NAME,SIZE,MODEL,VENDOR "$device"
    echo ""
    echo "This script will create a MODERN GPT/UEFI bootable USB:"
    echo "  - Partition 1: EFI System (${ESP_SIZE}MB, FAT32) — ISO + core packages"
    echo "  - Partition 2: Diagnostics (${DIAG_SIZE}MB, FAT32) — install logs"
    case "$secrets_action" in
        preserve) echo "  - Partition 3: SECRETS (PRESERVED — ext4)" ;;
        create)   echo "  - Partition 3: SECRETS (NEW — ${SECRETS_SIZE}MB, ext4) — keys/configs" ;;
    esac
    echo "  - Partition 4: STORAGE (remaining space, ext4) — Ollama, cloud images, large assets"
    echo ""
    read -rp "Are you sure you want to continue? (type 'yes' to proceed): " confirm

    if [ "$confirm" != "yes" ]; then
        error "Operation cancelled by user"
        exit 0
    fi
}

#===============================================================================
# USB PARTITIONING (GPT + UEFI)
#===============================================================================

partition_usb() {
    local device="$1"
    local has_secrets="$2"

    header "Creating GPT Partition Table"

    # Unmount any mounted partitions
    log "Unmounting any mounted partitions..."
    for part in "${device}"*; do
        if [ "$part" != "$device" ] && mountpoint -q "$part" 2>/dev/null; then
            umount "$part" || true
        fi
    done

    # Also unmount the device itself if mounted as ISO
    if mount | grep -q "^$device "; then
        umount "$device" || true
    fi

    sync
    sleep 2

    if [ "$has_secrets" = "true" ]; then
        # Preserve SECRETS partition — delete partitions 1, 2, and 4
        log "Preserving SECRETS partition (partition 3)..."
        sgdisk --delete=1 "$device" &>> "$LOG_FILE" || true
        sgdisk --delete=2 "$device" &>> "$LOG_FILE" || true
        sgdisk --delete=4 "$device" &>> "$LOG_FILE" || true
    else
        # Wipe existing partition table and create new GPT
        log "Creating fresh GPT partition table..."
        sgdisk --zap-all "$device" &>> "$LOG_FILE"
    fi

    # Sync and wait for device to settle
    sync
    sleep 2

    # Create partitions:
    # 1. EFI System Partition (10GB, FAT32) - ISO + core packages + scripts
    # 2. Diagnostics partition (1GB, FAT32) - install logs/debugging
    # 3. SECRETS (5GB, ext4) - keys, configs, wifi (persists across rebuilds)
    # 4. STORAGE (remaining, ext4) - Ollama, cloud images, large non-core assets

    log "Creating EFI System Partition (${ESP_SIZE}MB)..."
    sgdisk --new=1:0:+${ESP_SIZE}M --typecode=1:ef00 --change-name=1:"$ESP_LABEL" "$device" &>> "$LOG_FILE"

    log "Creating diagnostics partition (${DIAG_SIZE}MB)..."
    sgdisk --new=2:0:+${DIAG_SIZE}M --typecode=2:0700 --change-name=2:"$DIAG_LABEL" "$device" &>> "$LOG_FILE"

    # Print the new partition table
    sgdisk --print "$device" &>> "$LOG_FILE"

    # Inform kernel of partition changes
    partprobe "$device" 2>/dev/null || blockdev --rereadpt "$device" 2>/dev/null || true
    sync
    sleep 3

    log "✓ GPT partitions created"
}

format_partitions() {
    local device="$1"
    local esp_part="${device}1"
    local diag_part="${device}2"

    header "Formatting Partitions"

    # Handle different device naming (sdc vs nvme0n1)
    if [[ "$device" == *"nvme"* ]] || [[ "$device" == *"mmcblk"* ]]; then
        esp_part="${device}p1"
        diag_part="${device}p2"
    fi

    # Wait for partition devices to appear
    local retry=0
    while [ ! -b "$esp_part" ] && [ $retry -lt 10 ]; do
        log "Waiting for partition device to appear..."
        sleep 1
        retry=$((retry + 1))
    done

    if [ ! -b "$esp_part" ]; then
        error "Partition $esp_part not found after partitioning"
        exit 1
    fi

    # CRITICAL: Unmount any auto-mounted partitions before formatting
    # Desktop environments (GNOME, etc.) auto-mount new partitions immediately
    log "Checking for auto-mounted partitions..."
    for part in "$esp_part" "$diag_part"; do
        # Get mount point if mounted
        local mnt
        mnt=$(findmnt -n -o TARGET "$part" 2>/dev/null || true)
        if [ -n "$mnt" ]; then
            log "  Unmounting auto-mounted: $part ($mnt)"
            umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true
        fi
    done
    # Also try unmounting by common auto-mount paths
    for path in /media/*/UEFI_BOOT /media/*/DIAGNOSTICS /run/media/*/UEFI_BOOT /run/media/*/DIAGNOSTICS; do
        if [ -d "$path" ]; then
            umount "$path" 2>/dev/null || true
        fi
    done
    sleep 2

    # Format EFI System Partition (FAT32)
    log "Formatting EFI System Partition as FAT32..."
    mkfs.vfat -F32 -n "$ESP_LABEL" "$esp_part" &>> "$LOG_FILE"

    # Format diagnostics partition (FAT32 for maximum compatibility)
    log "Formatting diagnostics partition as FAT32..."
    mkfs.vfat -F32 -n "$DIAG_LABEL" "$diag_part" &>> "$LOG_FILE"

    sync
    sleep 2

    log "✓ Partitions formatted"
    log "  └─ $esp_part: FAT32 ($ESP_LABEL)"
    log "  └─ $diag_part: FAT32 ($DIAG_LABEL)"
}

#===============================================================================
# SECRETS PARTITION SETUP
#===============================================================================

setup_secrets_partition() {
    local device="$1"
    local secrets_action="$2"
    local secrets_part
    secrets_part=$(get_secrets_part "$device")

    if [ "$secrets_action" = "preserve" ]; then
        log "SECRETS partition preserved (ext4)"
        return 0
    fi

    header "Creating SECRETS Partition"

    log "Creating SECRETS partition (${SECRETS_SIZE}MB)..."
    sgdisk --new=3:0:+${SECRETS_SIZE}M --typecode=3:8300 --change-name=3:"$SECRETS_LABEL" "$device" &>> "$LOG_FILE"
    partprobe "$device" 2>/dev/null || blockdev --rereadpt "$device" 2>/dev/null || true
    sleep 3

    # Wait for partition device
    local retry=0
    while [ ! -b "$secrets_part" ] && [ $retry -lt 10 ]; do
        sleep 1
        retry=$((retry + 1))
    done
    if [ ! -b "$secrets_part" ]; then
        warn "SECRETS partition device not found ($secrets_part) — skipping setup"
        return 0
    fi

    # Unmount if auto-mounted
    umount "$secrets_part" 2>/dev/null || true
    for path in /media/*/SECRETS /run/media/*/SECRETS; do
        umount "$path" 2>/dev/null || true
    done
    sleep 1

    log "Formatting SECRETS partition as ext4..."
    mkfs.ext4 -L "$SECRETS_LABEL" "$secrets_part" -q &>> "$LOG_FILE"

    # Create template directory structure
    local secrets_mount="/tmp/secrets-setup-$$"
    mkdir -p "$secrets_mount"
    mount "$secrets_part" "$secrets_mount"

    mkdir -p "$secrets_mount/wireguard"
    mkdir -p "$secrets_mount/ssh"
    mkdir -p "$secrets_mount/api-keys"
    mkdir -p "$secrets_mount/wifi"
    chmod 700 "$secrets_mount/wireguard"
    chmod 700 "$secrets_mount/ssh"
    chmod 700 "$secrets_mount/api-keys"
    chmod 700 "$secrets_mount/wifi"

    cat > "$secrets_mount/README.txt" << 'SEOF'
SECRETS Partition
=================
Plain ext4 storage for sensitive files.
The USB itself is the security boundary — keep it physically secure.
Persists across USB rebuilds.

Directories:
  wireguard/   - WireGuard VPN configs (wg0.conf)
  wifi/        - NetworkManager wifi connections (.nmconnection)
  ssh/         - SSH keys
  api-keys/    - API keys and tokens

Management:
  sudo ./scripts/manage-secrets.sh list <device>
  sudo ./scripts/manage-secrets.sh add-wireguard <device> <wg0.conf>
SEOF

    umount "$secrets_mount"
    rmdir "$secrets_mount" 2>/dev/null || true

    log "✓ SECRETS partition created (ext4)"
    log "  └─ ${secrets_part}: ext4 ($SECRETS_LABEL)"
}

#===============================================================================
# STORAGE PARTITION SETUP
#===============================================================================

setup_storage_partition() {
    local device="$1"
    local storage_part
    storage_part=$(get_storage_part "$device")

    header "Creating STORAGE Partition"

    log "Creating STORAGE partition (remaining space)..."
    sgdisk --new=4:0:0 --typecode=4:8300 --change-name=4:"$STORAGE_LABEL" "$device" &>> "$LOG_FILE"
    partprobe "$device" 2>/dev/null || blockdev --rereadpt "$device" 2>/dev/null || true
    sleep 3

    # Wait for partition device
    local retry=0
    while [ ! -b "$storage_part" ] && [ $retry -lt 10 ]; do
        sleep 1
        retry=$((retry + 1))
    done
    if [ ! -b "$storage_part" ]; then
        warn "STORAGE partition device not found ($storage_part) — skipping setup"
        return 0
    fi

    # Unmount if auto-mounted
    umount "$storage_part" 2>/dev/null || true
    for path in /media/*/STORAGE /run/media/*/STORAGE; do
        umount "$path" 2>/dev/null || true
    done
    sleep 1

    log "Formatting STORAGE partition as ext4..."
    mkfs.ext4 -L "$STORAGE_LABEL" "$storage_part" -q &>> "$LOG_FILE"

    log "✓ STORAGE partition created (ext4)"
    log "  └─ ${storage_part}: ext4 ($STORAGE_LABEL)"
}

#===============================================================================
# ISO EXTRACTION
#===============================================================================

extract_iso_contents() {
    local iso="$1"
    local target_dir="$2"

    header "Extracting ISO Contents"

    log "Extracting Ubuntu ISO to USB..."
    log "This may take a few minutes..."

    # Extract ISO using xorriso (preserves all files including hidden .disk)
    # Note: FAT32 doesn't support symlinks, so we use:
    #   -abort_on NEVER: continue past errors
    #   -return_with SORRY 0: don't return non-zero exit code for SORRY/FAILURE events
    # Symlink failures (dists/stable, dists/unstable, ubuntu) are expected and harmless
    xorriso -osirrox on -indev "$iso" -extract / "$target_dir" -abort_on NEVER -return_with SORRY 0 &>> "$LOG_FILE"

    # Make all files writable (ISO extracts as read-only)
    chmod -R u+w "$target_dir" 2>/dev/null || true

    log "✓ ISO contents extracted"
}

#===============================================================================
# AUTOINSTALL INTEGRATION
#===============================================================================

add_autoinstall_files() {
    local esp_mount="$1"
    local autoinstall_dir="$2"

    header "Adding Autoinstall Files"

    # Create autoinstall directory in the root of ESP
    local target_dir="$esp_mount/usb-autoinstall"
    mkdir -p "$target_dir"

    # Copy autoinstall configuration
    log "Copying autoinstall configuration..."
    cp "$autoinstall_dir/user-data" "$target_dir/"
    cp "$autoinstall_dir/meta-data" "$target_dir/"

    # Copy packages if they exist
    # Note: Using --no-perms --no-owner --no-group because FAT32 doesn't support Unix permissions
    if [ -d "$autoinstall_dir/packages" ] && [ "$(ls -A "$autoinstall_dir/packages" 2>/dev/null)" ]; then
        log "Copying packages directory..."
        if ! rsync -r --no-perms --no-owner --no-group "$autoinstall_dir/packages/" "$target_dir/packages/" &>> "$LOG_FILE"; then
            error "Failed to copy packages (likely out of space on ESP partition)"
            df -h "$target_dir" | tee -a "$LOG_FILE"
            exit 1
        fi
        local pkg_count
        pkg_count=$(find "$target_dir/packages" -name "*.deb" 2>/dev/null | wc -l)
        log "  └─ $pkg_count packages copied"

        # Pre-generate apt package index so installer doesn't need dpkg-scanpackages
        log "Generating package index (Packages, Packages.gz)..."
        if command -v dpkg-scanpackages &>/dev/null; then
            (cd "$target_dir/packages" && dpkg-scanpackages . /dev/null > Packages 2>/dev/null && gzip -9c Packages > Packages.gz)
            local index_lines
            index_lines=$(wc -l < "$target_dir/packages/Packages" 2>/dev/null || echo 0)
            log "  └─ Package index: $index_lines lines"
        else
            warn "dpkg-scanpackages not available — index must be generated at install time"
        fi
    else
        warn "No packages found - will download during install"
        mkdir -p "$target_dir/packages"
    fi

    # Copy scripts
    if [ -d "$autoinstall_dir/scripts" ]; then
        log "Copying scripts directory..."
        rsync -r --no-perms --no-owner --no-group "$autoinstall_dir/scripts/" "$target_dir/scripts/" &>> "$LOG_FILE"
        chmod +x "$target_dir/scripts"/*.sh 2>/dev/null || true
    fi

    # Copy files directory (core configs, systemd units)
    if [ -d "$autoinstall_dir/files" ]; then
        log "Copying files directory..."
        rsync -r --no-perms --no-owner --no-group "$autoinstall_dir/files/" "$target_dir/files/" &>> "$LOG_FILE"
    fi

    # Copy components directory (security, devtools, dashboard, ollama)
    if [ -d "$autoinstall_dir/components" ]; then
        log "Copying components directory..."
        rsync -r --no-perms --no-owner --no-group "$autoinstall_dir/components/" "$target_dir/components/" &>> "$LOG_FILE"
        # Ensure install scripts are executable
        find "$target_dir/components" -name "install.sh" -exec chmod +x {} \; 2>/dev/null || true
    fi

    # Copy documentation
    if [ -f "$autoinstall_dir/README.md" ]; then
        cp "$autoinstall_dir/README.md" "$target_dir/"
    fi
    if [ -d "$autoinstall_dir/docs" ]; then
        rsync -r --no-perms --no-owner --no-group "$autoinstall_dir/docs/" "$target_dir/docs/" &>> "$LOG_FILE"
    fi

    log "✓ Autoinstall files added to USB"
}

add_storage_files() {
    local storage_mount="$1"
    local autoinstall_dir="$2"

    header "Adding Files to STORAGE Partition"

    # Copy Ollama binary archive (for local LLM inference)
    if [ -d "$autoinstall_dir/ollama" ] && [ "$(ls -A "$autoinstall_dir/ollama" 2>/dev/null)" ]; then
        log "Copying Ollama directory (~1.7GB)..."
        if ! rsync -r "$autoinstall_dir/ollama/" "$storage_mount/ollama/" &>> "$LOG_FILE"; then
            error "Failed to copy Ollama directory (likely out of space on STORAGE partition)"
            df -h "$storage_mount" | tee -a "$LOG_FILE"
            exit 1
        fi
        log "  └─ Ollama archive copied"
    else
        warn "No Ollama directory found — local AI models won't be available offline"
    fi

    # Copy cloud images (for AI sandbox VMs)
    if [ -d "$autoinstall_dir/cloud-images" ] && [ "$(ls -A "$autoinstall_dir/cloud-images" 2>/dev/null)" ]; then
        log "Copying cloud images directory (~600MB)..."
        if ! rsync -r "$autoinstall_dir/cloud-images/" "$storage_mount/cloud-images/" &>> "$LOG_FILE"; then
            error "Failed to copy cloud images (likely out of space on STORAGE partition)"
            df -h "$storage_mount" | tee -a "$LOG_FILE"
            exit 1
        fi
        log "  └─ Cloud images copied"
    else
        warn "No cloud images found — AI sandbox VMs will need to download images"
    fi

    log "✓ STORAGE files added to USB"
}

modify_grub_config() {
    local esp_mount="$1"

    header "Configuring GRUB for Autoinstall"

    local grub_cfg="$esp_mount/boot/grub/grub.cfg"

    if [ ! -f "$grub_cfg" ]; then
        error "GRUB config not found: $grub_cfg"
        exit 1
    fi

    # Backup original
    cp "$grub_cfg" "$grub_cfg.orig"

    log "Modifying GRUB configuration for autoinstall..."

    # CRITICAL: The semicolon MUST be escaped as \; in GRUB config
    # Otherwise GRUB interprets it as a command separator and truncates the ds= parameter
    # We use awk for reliable escaping instead of sed (which has escaping issues)
    # Note: awk uses [ \t] for whitespace, not \s (which is Perl regex)

    # Use sed with $'...' syntax to handle literal tabs and proper backslash escaping
    # The grub.cfg uses tabs (not spaces): \tlinux\t/casper/vmlinuz
    sed -i $'s|\tlinux\t/casper/vmlinuz.*---|\tlinux\t/casper/vmlinuz autoinstall ds=nocloud\\\;s=/cdrom/usb-autoinstall/ quiet splash ---|' "$grub_cfg"

    # Set shorter timeout (5 seconds)
    sed -i 's/^set timeout=.*/set timeout=5/' "$grub_cfg"

    # Ensure default is first entry
    if ! grep -q "^set default=" "$grub_cfg"; then
        sed -i '1i set default=0' "$grub_cfg"
    fi

    # VERIFY the fix was applied correctly
    # Note: In the file, it's stored as single backslash: ds=nocloud\;s=
    # We use grep -F for literal matching to avoid regex interpretation
    if grep -qF 'ds=nocloud\;s=' "$grub_cfg"; then
        log "✓ GRUB configuration modified (semicolon properly escaped)"
    else
        error "GRUB modification may have failed - semicolon escaping not detected"
        error "Please verify $grub_cfg manually"
    fi
    log "  └─ Boot parameters: autoinstall ds=nocloud\\;s=/cdrom/usb-autoinstall/"
}

#===============================================================================
# GRUB INSTALLATION
#===============================================================================

install_grub_bootloader() {
    local device="$1"
    local esp_mount="$2"

    header "Installing GRUB Bootloader"

    log "Installing GRUB for UEFI boot..."

    # Install GRUB to the EFI System Partition
    # --target=x86_64-efi: 64-bit UEFI
    # --efi-directory: Where the ESP is mounted
    # --boot-directory: Where GRUB files are
    # --removable: Creates fallback bootloader path (BOOTX64.EFI) for maximum compatibility
    # --no-nvram: Don't modify system NVRAM (important for USB creation)
    grub-install \
        --target=x86_64-efi \
        --efi-directory="$esp_mount" \
        --boot-directory="$esp_mount/boot" \
        --removable \
        --no-nvram \
        "$device" &>> "$LOG_FILE"

    # Verify the bootloader was installed
    if [ ! -f "$esp_mount/EFI/BOOT/BOOTX64.EFI" ]; then
        error "GRUB bootloader not found at expected location"
        exit 1
    fi

    log "✓ GRUB bootloader installed"
    log "  └─ Bootloader: $esp_mount/EFI/BOOT/BOOTX64.EFI"
}

#===============================================================================
# DIAGNOSTICS PARTITION SETUP
#===============================================================================

setup_diagnostics_partition() {
    local diag_mount="$1"

    header "Setting Up Diagnostics Partition"

    # Create directory structure for diagnostics
    mkdir -p "$diag_mount/logs"
    mkdir -p "$diag_mount/debug"

    # Create README
    cat > "$diag_mount/README.txt" << 'EOF'
Ubuntu Autoinstall - Diagnostics Partition
==========================================

This partition can be used for debugging and logging during installation.

Directories:
  /logs/  - Installation logs and debug output
  /debug/ - Debug files and troubleshooting information

Usage:
  During installation, you can mount this partition to save logs:
    mount /dev/disk/by-label/DIAGNOSTICS /mnt
    cp /var/log/installer/* /mnt/logs/

  After installation, mount on another system to review logs:
    mount /dev/sdX2 /mnt
    cat /mnt/logs/*

This partition is writable and can be used for any debugging needs.
EOF

    log "✓ Diagnostics partition configured"
    log "  └─ Mount this partition to save installation logs"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    header "Native GPT UEFI USB Creator v3.0"

    # Parse arguments
    if [ $# -lt 2 ]; then
        error "Usage: $0 <ubuntu-iso> <usb-device> [autoinstall-dir]"
        error ""
        error "Example:"
        error "  sudo $0 ubuntu-25.10-live-server-amd64.iso /dev/sdc"
        error "  sudo $0 ubuntu-25.10-live-server-amd64.iso /dev/sdc /mnt/sda2/usb-autoinstall"
        exit 1
    fi

    local ubuntu_iso="$1"
    local usb_device="$2"
    local autoinstall_dir="${3:-$PROJECT_DIR}"

    # Convert to absolute paths
    ubuntu_iso="$(realpath "$ubuntu_iso")"
    autoinstall_dir="$(realpath "$autoinstall_dir")"

    # Determine partition naming scheme
    local esp_part diag_part storage_part
    esp_part=$(get_part "$usb_device" 1)
    diag_part=$(get_part "$usb_device" 2)
    storage_part=$(get_storage_part "$usb_device")

    # Detect existing SECRETS partition
    local secrets_part
    secrets_part=$(get_secrets_part "$usb_device")
    local has_secrets="false"
    local secrets_action="create"  # create or preserve
    if [ -b "$secrets_part" ]; then
        local secrets_fstype
        secrets_fstype=$(blkid -s TYPE -o value "$secrets_part" 2>/dev/null || true)
        if [ "$secrets_fstype" = "ext4" ]; then
            has_secrets="true"
            secrets_action="preserve"
        fi
    fi

    log "Configuration:"
    log "  Ubuntu ISO: $ubuntu_iso"
    log "  USB Device: $usb_device"
    log "  Autoinstall Dir: $autoinstall_dir"
    log "  Work Directory: $WORK_DIR"
    log "  Log File: $LOG_FILE"
    case "$secrets_action" in
        preserve) log "  SECRETS partition: DETECTED ext4 (will preserve)" ;;
        create)   log "  SECRETS partition: not found (will create new)" ;;
    esac
    log ""
    log "Partition layout:"
    log "  ${esp_part}: EFI System Partition (${ESP_SIZE}MB, FAT32)"
    log "  ${diag_part}: Diagnostics (${DIAG_SIZE}MB, FAT32)"
    case "$secrets_action" in
        preserve) log "  ${secrets_part}: SECRETS (ext4, preserved)" ;;
        create)   log "  ${secrets_part}: SECRETS (${SECRETS_SIZE}MB, ext4, new)" ;;
    esac
    log "  ${storage_part}: STORAGE (remaining space, ext4)"

    # Validation
    check_root
    check_requirements
    validate_iso "$ubuntu_iso"
    validate_usb "$usb_device"
    validate_autoinstall "$autoinstall_dir"
    confirm_action "$usb_device" "$has_secrets" "$secrets_action"

    # Create working directory
    mkdir -p "$WORK_DIR"
    mkdir -p "$WORK_DIR/esp"
    mkdir -p "$WORK_DIR/diag"
    mkdir -p "$WORK_DIR/storage"

    # Partition and format USB
    partition_usb "$usb_device" "$has_secrets"
    format_partitions "$usb_device"
    setup_secrets_partition "$usb_device" "$secrets_action"
    setup_storage_partition "$usb_device"

    # Mount partitions
    header "Mounting Partitions"

    # CRITICAL: Unmount any auto-mounted partitions first
    # Desktop environments often auto-mount newly formatted partitions
    log "Checking for auto-mounted partitions..."
    for mp in $(mount | grep -E "$esp_part|$diag_part|$storage_part" | awk '{print $3}'); do
        log "  Unmounting auto-mounted: $mp"
        umount "$mp" 2>/dev/null || true
    done
    # Also unmount by label (common auto-mount behavior)
    for lbl in UEFI_BOOT DIAGNOSTICS STORAGE; do
        umount "/media/$USER/$lbl" 2>/dev/null || true
        umount "/media/"*"/$lbl" 2>/dev/null || true
    done
    sleep 2  # Give system time to release devices

    log "Mounting EFI System Partition..."
    mount "$esp_part" "$WORK_DIR/esp"
    log "Mounting diagnostics partition..."
    mount "$diag_part" "$WORK_DIR/diag"
    log "Mounting STORAGE partition..."
    mount "$storage_part" "$WORK_DIR/storage"
    log "✓ Partitions mounted"

    # Extract ISO and setup autoinstall
    extract_iso_contents "$ubuntu_iso" "$WORK_DIR/esp"
    add_autoinstall_files "$WORK_DIR/esp" "$autoinstall_dir"
    add_storage_files "$WORK_DIR/storage" "$autoinstall_dir"
    install_grub_bootloader "$usb_device" "$WORK_DIR/esp"
    # IMPORTANT: modify_grub_config must run AFTER install_grub_bootloader
    # because grub-install overwrites grub.cfg with a default one
    modify_grub_config "$WORK_DIR/esp"
    setup_diagnostics_partition "$WORK_DIR/diag"

    # Unmount and sync
    header "Finalizing USB"
    log "Unmounting partitions..."
    umount "$WORK_DIR/storage"
    umount "$WORK_DIR/esp"
    umount "$WORK_DIR/diag"

    log "Syncing data to USB..."
    sync
    sleep 2

    # Success
    header "✅ SUCCESS!"
    echo ""
    log "Native GPT UEFI bootable USB created successfully!"
    log ""
    log "USB Layout:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$usb_device" | tee -a "$LOG_FILE"
    echo ""
    case "$secrets_action" in
        preserve) log "SECRETS partition preserved on ${secrets_part}" ;;
        create)   log "SECRETS partition created on ${secrets_part}" ;;
    esac
    log "STORAGE partition on ${storage_part}"
    log "  Add secrets with: sudo ./scripts/manage-secrets.sh add-wireguard $usb_device <wg0.conf>"
    log ""
    log "Next steps:"
    log "  1. Safely remove USB: sync && eject $usb_device"
    log "  2. Insert USB into target system"
    log "  3. Enter BIOS (Delete key during boot)"
    log "  4. Select USB drive from boot menu (F11 or boot priority)"
    log "  5. Installation will start automatically"
    log "  6. Enter LUKS passphrase when prompted"
    log "  7. Wait for completion (~15 minutes)"
    log ""
    log "BIOS Settings (if USB doesn't appear):"
    log "  - Disable Secure Boot"
    log "  - Ensure UEFI boot mode is enabled"
    log "  - Check boot priority includes USB devices"
    log ""
    log "Diagnostics:"
    log "  - Mount ${diag_part} on another system to save/review logs"
    log "  - Installation logs: /var/log/cloud-init-output.log"
    log ""
    log "Full log saved to: $LOG_FILE"

    # Offer to copy log to diagnostics partition
    if [ -f "$LOG_FILE" ]; then
        mount "$diag_part" "$WORK_DIR/diag" 2>/dev/null || true
        if mountpoint -q "$WORK_DIR/diag" 2>/dev/null; then
            cp "$LOG_FILE" "$WORK_DIR/diag/logs/usb-creation.log"
            umount "$WORK_DIR/diag"
            log "✓ Creation log saved to diagnostics partition"
        fi
    fi
}

# Run main
main "$@"
