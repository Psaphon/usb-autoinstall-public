#!/bin/bash
#===============================================================================
# SECRETS Partition Management Utility
#===============================================================================
# Description: Manages a plain ext4 SECRETS partition on the USB drive
#              for storing VPN configs, SSH keys, and API keys.
# Version: 2.0.0
#
# Usage:
#   sudo ./manage-secrets.sh init <device>
#   sudo ./manage-secrets.sh add-wireguard <device> <wg0.conf>
#   sudo ./manage-secrets.sh list <device>
#   sudo ./manage-secrets.sh open <device>
#   sudo ./manage-secrets.sh close
#
# The SECRETS partition is partition 3 on the USB device.
# It uses plain ext4 — the USB itself is the security boundary.
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

SECRETS_LABEL="SECRETS"
SECRETS_MOUNT="/media/secrets"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#===============================================================================
# HELPERS
#===============================================================================

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
}

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

# Get partition 3 device path for a given base device
get_secrets_part() {
    get_part "$1" 3
}

# Check if SECRETS partition exists and is ext4
check_secrets_exists() {
    local part="$1"
    if [ ! -b "$part" ]; then
        return 1
    fi
    local fstype
    fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || true)
    if [ "$fstype" != "ext4" ]; then
        return 1
    fi
    return 0
}

# Open (mount) SECRETS partition
secrets_open() {
    local part="$1"

    if mountpoint -q "$SECRETS_MOUNT" 2>/dev/null; then
        log "SECRETS already mounted at $SECRETS_MOUNT"
        return 0
    fi

    # Check if mounted elsewhere (desktop auto-mount)
    local existing_mount
    existing_mount=$(findmnt -n -o TARGET "$part" 2>/dev/null || true)
    if [ -n "$existing_mount" ] && [ "$existing_mount" != "$SECRETS_MOUNT" ]; then
        log "SECRETS auto-mounted at $existing_mount — remounting to $SECRETS_MOUNT"
        umount "$existing_mount" 2>/dev/null || true
    fi

    mkdir -p "$SECRETS_MOUNT"
    mount "$part" "$SECRETS_MOUNT"
    log "SECRETS mounted at $SECRETS_MOUNT"
}

# Close (unmount) SECRETS partition
secrets_close() {
    if mountpoint -q "$SECRETS_MOUNT" 2>/dev/null; then
        umount "$SECRETS_MOUNT"
        log "SECRETS unmounted"
    fi

    # Also check for desktop auto-mounts
    for mnt in /media/*/SECRETS /run/media/*/SECRETS; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount "$mnt" 2>/dev/null || true
            log "Unmounted auto-mount: $mnt"
        fi
    done
}

#===============================================================================
# SUBCOMMANDS
#===============================================================================

cmd_init() {
    local device="$1"
    local part
    part=$(get_secrets_part "$device")

    if [ ! -b "$device" ]; then
        error "Device not found: $device"
        exit 1
    fi

    # Check that partition 1 exists (USB was already created)
    local part1
    part1=$(get_part "$device" 1)
    if [ ! -b "$part1" ]; then
        error "Partition 1 not found — run create-bootable-usb.sh first"
        exit 1
    fi

    if [ -b "$part" ]; then
        local fstype
        fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || true)
        if [ "$fstype" = "ext4" ]; then
            warn "SECRETS partition already exists at $part"
            read -rp "Reinitialize? This will DESTROY all secrets. (type 'yes'): " confirm
            if [ "$confirm" != "yes" ]; then
                error "Cancelled"
                exit 0
            fi
        else
            warn "Partition 3 exists but is not ext4 ($fstype) — will overwrite"
            read -rp "Continue? (type 'yes'): " confirm
            if [ "$confirm" != "yes" ]; then
                error "Cancelled"
                exit 0
            fi
        fi
        # Unmount and close if open
        secrets_close 2>/dev/null || true
        # Delete existing partition 3
        sgdisk --delete=3 "$device" 2>/dev/null || true
        partprobe "$device" 2>/dev/null || true
        sleep 2
    fi

    log "Creating SECRETS partition (remaining space)..."
    sgdisk --new=3:0:0 --typecode=3:8300 --change-name=3:"$SECRETS_LABEL" "$device"
    partprobe "$device" 2>/dev/null || blockdev --rereadpt "$device" 2>/dev/null || true
    sleep 3

    # Wait for partition device
    local retry=0
    while [ ! -b "$part" ] && [ $retry -lt 10 ]; do
        sleep 1
        retry=$((retry + 1))
    done
    if [ ! -b "$part" ]; then
        error "Partition $part not found after creation"
        exit 1
    fi

    log "Creating ext4 filesystem..."
    mkfs.ext4 -L "$SECRETS_LABEL" "$part" -q

    mkdir -p "$SECRETS_MOUNT"
    mount "$part" "$SECRETS_MOUNT"

    log "Creating directory structure..."
    mkdir -p "$SECRETS_MOUNT/wireguard"
    mkdir -p "$SECRETS_MOUNT/ssh"
    mkdir -p "$SECRETS_MOUNT/api-keys"
    mkdir -p "$SECRETS_MOUNT/wifi"
    chmod 700 "$SECRETS_MOUNT/wireguard"
    chmod 700 "$SECRETS_MOUNT/ssh"
    chmod 700 "$SECRETS_MOUNT/api-keys"
    chmod 700 "$SECRETS_MOUNT/wifi"

    cat > "$SECRETS_MOUNT/README.txt" << 'EOF'
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
EOF

    secrets_close

    echo ""
    log "SECRETS partition initialized on $part (plain ext4)"
    log "Use 'manage-secrets.sh add-wireguard' to add your VPN config"
}

cmd_add_wireguard() {
    local device="$1"
    local config_file="$2"
    local part
    part=$(get_secrets_part "$device")

    if [ ! -f "$config_file" ]; then
        error "Config file not found: $config_file"
        exit 1
    fi

    if ! check_secrets_exists "$part"; then
        error "No SECRETS partition on $device — run 'init' first"
        exit 1
    fi

    secrets_open "$part"

    cp "$config_file" "$SECRETS_MOUNT/wireguard/wg0.conf"
    chmod 600 "$SECRETS_MOUNT/wireguard/wg0.conf"
    log "WireGuard config copied to SECRETS partition"

    secrets_close
}

cmd_add_wifi() {
    local device="$1"
    local ssid="$2"
    local password="$3"
    local part
    part=$(get_secrets_part "$device")

    if ! check_secrets_exists "$part"; then
        error "No SECRETS partition on $device — run 'init' first"
        exit 1
    fi

    secrets_open "$part"

    mkdir -p "$SECRETS_MOUNT/wifi"
    local conn_file="$SECRETS_MOUNT/wifi/${ssid}.nmconnection"
    local conn_uuid
    conn_uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > "$conn_file" << NMEOF
[connection]
id=${ssid}
uuid=${conn_uuid}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${ssid}

[wifi-security]
key-mgmt=wpa-psk
psk=${password}

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
    chmod 600 "$conn_file"
    log "Wifi connection '${ssid}' saved to SECRETS"

    secrets_close
}

cmd_list() {
    local device="$1"
    local part
    part=$(get_secrets_part "$device")

    if ! check_secrets_exists "$part"; then
        error "No SECRETS partition on $device"
        exit 1
    fi

    secrets_open "$part"

    echo ""
    echo -e "${BLUE}SECRETS partition contents:${NC}"
    echo "──────────────────────────"
    for dir in wireguard ssh api-keys wifi; do
        local dirpath="$SECRETS_MOUNT/$dir"
        if [ -d "$dirpath" ]; then
            local count
            count=$(find "$dirpath" -maxdepth 1 -type f | wc -l)
            echo -e "  ${GREEN}$dir/${NC} ($count files)"
            find "$dirpath" -maxdepth 1 -type f -printf "    %f (%s bytes)\n" 2>/dev/null || true
        fi
    done
    echo ""

    secrets_close
}

cmd_open() {
    local device="$1"
    local part
    part=$(get_secrets_part "$device")

    if ! check_secrets_exists "$part"; then
        error "No SECRETS partition on $device"
        exit 1
    fi

    secrets_open "$part"
    log "SECRETS partition is open at $SECRETS_MOUNT"
    log "Run 'manage-secrets.sh close' when done"
}

cmd_close() {
    secrets_close
    log "SECRETS partition closed"
}

#===============================================================================
# USAGE
#===============================================================================

usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  init <device>                       Create SECRETS partition on USB"
    echo "  add-wireguard <device> <file>       Copy WireGuard config to SECRETS"
    echo "  add-wifi <device> <ssid> <password> Add wifi connection to SECRETS"
    echo "  list <device>                       Show SECRETS contents"
    echo "  open <device>                       Mount SECRETS"
    echo "  close                               Unmount SECRETS"
    echo ""
    echo "Example:"
    echo "  sudo $0 init /dev/sdb"
    echo "  sudo $0 add-wireguard /dev/sdb ~/wg0.conf"
    echo "  sudo $0 add-wifi /dev/sdb MyNetwork mypassword"
    echo "  sudo $0 list /dev/sdb"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    check_root

    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        init)
            [ $# -lt 1 ] && { error "Usage: $0 init <device>"; exit 1; }
            cmd_init "$1"
            ;;
        add-wireguard)
            [ $# -lt 2 ] && { error "Usage: $0 add-wireguard <device> <wg0.conf>"; exit 1; }
            cmd_add_wireguard "$1" "$2"
            ;;
        add-wifi)
            [ $# -lt 3 ] && { error "Usage: $0 add-wifi <device> <ssid> <password>"; exit 1; }
            cmd_add_wifi "$1" "$2" "$3"
            ;;
        list)
            [ $# -lt 1 ] && { error "Usage: $0 list <device>"; exit 1; }
            cmd_list "$1"
            ;;
        open)
            [ $# -lt 1 ] && { error "Usage: $0 open <device>"; exit 1; }
            cmd_open "$1"
            ;;
        close)
            cmd_close
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
