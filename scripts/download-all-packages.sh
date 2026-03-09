#!/usr/bin/env bash
#===============================================================================
# Download All Packages Script - Full Offline Support
#===============================================================================
# Description: Downloads ALL required packages with full dependencies for
#              completely offline USB installation (no network required)
# Usage: sudo ./download-all-packages.sh
# Author: Ephemeral Security Workstation Project
# Version: 3.0.0
#
# Reads package lists from:
#   - packages.list          (core desktop, network, python, etc.)
#   - components/*/packages.list (security, devtools, dashboard, ollama)
#
# Also downloads separately:
#   - Docker packages from Docker's repository
#   - Firefox from Mozilla's APT repo (Ubuntu's is a snap stub)
#   - VS Code from Microsoft
#   - Ubuntu cloud image for AI sandbox VMs
#   - Ollama binary for local LLM inference
#
# Total download size: ~1.5-2GB (XFCE desktop + all dependencies)
#===============================================================================

set -euo pipefail

#==============================================================================#
# CONSTANTS
#==============================================================================#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_DIR="$SCRIPT_DIR/.."
readonly PACKAGES_DIR="$REPO_DIR/packages"
readonly COMPONENTS_DIR="$REPO_DIR/components"

readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Docker packages need a separate repo — detect these in the package list
# and handle them specially
readonly DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

#==============================================================================#
# FUNCTIONS
#==============================================================================#

read_packages_list() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return
    fi
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        line=$(echo "$line" | xargs)  # trim whitespace
        [ -z "$line" ] && continue
        echo "$line"
    done < "$file"
}

is_docker_package() {
    local pkg="$1"
    for dpkg in "${DOCKER_PACKAGES[@]}"; do
        [[ "$pkg" == "$dpkg" ]] && return 0
    done
    return 1
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        log_error "Usage: sudo $0"
        exit 1
    fi
}

setup_docker_repo() {
    log_info "Setting up Docker repository..."

    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $( # shellcheck source=/dev/null
         . /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq

    log_success "Docker repository configured"
}

get_all_dependencies() {
    local package="$1"

    # Get full recursive dependency tree
    # Filter out virtual packages (those with : or | in the name)
    apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        "$package" 2>/dev/null | \
        grep "^\w" | \
        grep -v "^<" | \
        sort -u
}

download_package_with_deps() {
    local package="$1"
    local dep_file="/tmp/deps_$$.txt"

    log_info "Getting dependencies for $package..."

    # Get all dependencies
    if ! get_all_dependencies "$package" > "$dep_file" 2>/dev/null; then
        log_warning "Could not get dependencies for $package"
        return
    fi

    local dep_count
    dep_count=$(wc -l < "$dep_file")
    log_info "  Found $dep_count dependencies for $package"

    # Download each dependency
    while IFS= read -r dep; do
        if [ -n "$dep" ]; then
            # Skip if already downloaded
            if ls "$PACKAGES_DIR"/"${dep}"_*.deb >/dev/null 2>&1 || \
               ls "$PACKAGES_DIR"/"${dep}":*.deb >/dev/null 2>&1; then
                continue
            fi
            apt-get download "$dep" -o Dir::Cache::archives="$PACKAGES_DIR" 2>/dev/null || true
        fi
    done < "$dep_file"

    rm -f "$dep_file"
}

download_all_ubuntu_packages() {
    log_info "Reading package lists..."

    # Collect all packages from packages.list files (core + components)
    local all_packages=()
    local ubuntu_packages=()

    # Core packages
    if [ -f "$REPO_DIR/packages.list" ]; then
        log_info "  Reading core packages.list..."
        while IFS= read -r pkg; do
            all_packages+=("$pkg")
        done < <(read_packages_list "$REPO_DIR/packages.list")
    fi

    # Component packages
    for plist in "$COMPONENTS_DIR"/*/packages.list; do
        [ -f "$plist" ] || continue
        local component_name
        component_name=$(basename "$(dirname "$plist")")
        log_info "  Reading $component_name/packages.list..."
        while IFS= read -r pkg; do
            all_packages+=("$pkg")
        done < <(read_packages_list "$plist")
    done

    # Separate Docker packages (need Docker repo) from Ubuntu packages
    for pkg in "${all_packages[@]}"; do
        if ! is_docker_package "$pkg"; then
            ubuntu_packages+=("$pkg")
        fi
    done

    log_info "Downloading ${#ubuntu_packages[@]} Ubuntu packages with full dependencies..."
    log_info "This will take a while (~10-20 minutes)..."

    mkdir -p "$PACKAGES_DIR"
    cd "$PACKAGES_DIR"

    local total=${#ubuntu_packages[@]}
    local current=0

    for pkg in "${ubuntu_packages[@]}"; do
        current=$((current + 1))
        echo -e "${BLUE}[$current/$total]${NC} Processing $pkg..."
        download_package_with_deps "$pkg"
    done

    log_success "Ubuntu packages downloaded"
}

download_docker_packages() {
    # Check if any Docker packages are needed (listed in component packages.list)
    local docker_needed=false
    for plist in "$REPO_DIR/packages.list" "$COMPONENTS_DIR"/*/packages.list; do
        [ -f "$plist" ] || continue
        while IFS= read -r pkg; do
            if is_docker_package "$pkg"; then
                docker_needed=true
                break
            fi
        done < <(read_packages_list "$plist")
        $docker_needed && break
    done

    if ! $docker_needed; then
        log_info "No Docker packages in any packages.list — skipping Docker download"
        return 0
    fi

    log_info "Downloading Docker packages..."

    cd "$PACKAGES_DIR"

    for pkg in "${DOCKER_PACKAGES[@]}"; do
        log_info "  Downloading $pkg..."
        apt-get download "$pkg" 2>/dev/null || log_warning "Failed to download $pkg"
    done

    # Also get containerd dependencies
    download_package_with_deps "containerd.io"

    log_success "Docker packages downloaded"
}

download_firefox() {
    log_info "Downloading Firefox from Mozilla APT repository..."

    # Ubuntu 25.10's firefox package is a snap transition stub that calls
    # `snap install firefox` — which fails completely offline. We must pull
    # the real binary .deb from Mozilla's official APT repo instead.

    # Add Mozilla's signing key
    mkdir -p /etc/apt/keyrings
    local keyring="/etc/apt/keyrings/packages.mozilla.org.asc"
    if [ ! -f "$keyring" ]; then
        wget -q "https://packages.mozilla.org/apt/repo-signing-key.gpg" -O "$keyring" || {
            log_error "Failed to download Mozilla signing key"
            return 1
        }
    fi

    # Add Mozilla APT source (temporarily)
    local mozilla_list="/etc/apt/sources.list.d/mozilla-firefox.list"
    echo "deb [signed-by=${keyring}] https://packages.mozilla.org/apt mozilla main" > "$mozilla_list"

    # Pin Mozilla's Firefox higher than Ubuntu's snap stub so apt-get download
    # pulls the real .deb rather than the transition package
    local pin_file="/etc/apt/preferences.d/mozilla-firefox"
    cat > "$pin_file" << 'PINEOF'
Package: firefox*
Pin: origin packages.mozilla.org
Pin-Priority: 1001
PINEOF

    apt-get update -qq

    cd "$PACKAGES_DIR"

    # Remove any snap stub firefox .debs (from previous runs or dep resolution)
    # The snap stub version contains "snap" in the filename (e.g. firefox_1%3a1snap1-...)
    rm -f firefox_*snap*_*.deb

    apt-get download firefox 2>/dev/null || {
        log_error "Failed to download Firefox from Mozilla repo"
        rm -f "$mozilla_list" "$pin_file"
        return 1
    }

    # Download Firefox dependencies that may not be in Ubuntu's repos
    download_package_with_deps firefox

    # Final cleanup: remove any snap stub that snuck in via dependency resolution
    rm -f firefox_*snap*_*.deb

    # Clean up temporary repo config — leave the keyring so it can be reused
    # on subsequent runs without re-downloading
    rm -f "$mozilla_list" "$pin_file"

    log_success "Firefox downloaded from Mozilla APT repository"
}

download_vscode() {
    log_info "Downloading VS Code..."

    cd "$PACKAGES_DIR"

    # Download latest VS Code .deb directly from Microsoft
    local vscode_url="https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64"

    if wget -q --show-progress -O code_latest_amd64.deb "$vscode_url"; then
        log_success "VS Code downloaded successfully"
    else
        log_warning "Failed to download VS Code - will be skipped during offline install"
    fi
}

download_cloud_image() {
    log_info "Downloading Ubuntu 24.04 minimal cloud image for AI sandbox..."

    local cloud_dir="$PACKAGES_DIR/../cloud-images"
    mkdir -p "$cloud_dir"

    local image_url="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
    local image_file="$cloud_dir/ubuntu-24.04-minimal-cloudimg-amd64.img"

    if [ -f "$image_file" ]; then
        log_info "Cloud image already downloaded — skipping"
        return 0
    fi

    log_info "Downloading cloud image (~600MB)..."
    if wget -q --show-progress -O "$image_file" "$image_url"; then
        log_success "Cloud image downloaded: $image_file"
    else
        rm -f "$image_file"
        log_error "Failed to download cloud image"
        return 1
    fi
}

download_ollama() {
    log_info "Downloading Ollama binary for local LLM inference..."

    local ollama_dir="$PACKAGES_DIR/../ollama"
    mkdir -p "$ollama_dir"

    local ollama_url="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst"
    local ollama_file="$ollama_dir/ollama-linux-amd64.tar.zst"

    if [ -f "$ollama_file" ]; then
        log_info "Ollama binary already downloaded — skipping"
        return 0
    fi

    log_info "Downloading Ollama (~1.7GB, includes CUDA GPU libraries)..."
    if wget --show-progress -O "$ollama_file" "$ollama_url"; then
        log_success "Ollama binary downloaded: $ollama_file"
    else
        rm -f "$ollama_file"
        log_error "Failed to download Ollama binary"
        return 1
    fi
}

generate_package_index() {
    log_info "Generating package index for apt..."

    cd "$PACKAGES_DIR"

    # Generate Packages file (required for apt to use local repo)
    dpkg-scanpackages . /dev/null > Packages 2>/dev/null
    gzip -9c Packages > Packages.gz

    # Also create Release file for completeness
    cat > Release << EOF
Archive: stable
Component: main
Origin: USB Autoinstall
Label: USB Autoinstall Offline Packages
Architecture: amd64
EOF

    log_success "Package index generated"
}

generate_checksums() {
    log_info "Generating package checksums..."

    cd "$PACKAGES_DIR"

    # Remove old checksum file
    rm -f SHA256SUMS

    # Generate new checksums
    sha256sum ./*.deb > SHA256SUMS 2>/dev/null || {
        log_warning "No .deb files found to checksum"
        echo "# No packages yet" > SHA256SUMS
    }

    local package_count
    package_count=$(find . -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)

    log_success "Checksums generated for $package_count packages"
}

cleanup_duplicates() {
    log_info "Cleaning up duplicate package versions..."

    cd "$PACKAGES_DIR"

    # Find and remove older versions of packages (keep newest)
    # This is a simple approach - keeps files with highest version number
    local removed=0

    for pkg in $(find . -maxdepth 1 -name "*.deb" -printf '%f\n' 2>/dev/null | sed 's/_[^_]*$//' | sort -u); do
        local versions
        versions=$(find . -maxdepth 1 -name "${pkg}_*.deb" -printf '%f\n' 2>/dev/null | sort -V)
        local count
        count=$(echo "$versions" | wc -l)

        if [ "$count" -gt 1 ]; then
            # Remove all but the last (newest) version
            echo "$versions" | head -n -1 | while read -r old_version; do
                rm -f "$old_version"
                removed=$((removed + 1))
            done
        fi
    done

    log_info "Removed $removed duplicate package versions"
}

show_summary() {
    cd "$PACKAGES_DIR"

    local package_count
    local total_size

    package_count=$(find . -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
    total_size=$(du -sh . | awk '{print $1}')

    echo ""
    echo "==============================================================================="
    log_success "Full Offline Package Download Complete"
    echo "==============================================================================="
    echo ""
    echo "Statistics:"
    echo "  Total packages: $package_count"
    echo "  Total size: $total_size"
    echo "  Location: $PACKAGES_DIR"
    echo ""
    echo "Package sources:"
    if [ -f "$REPO_DIR/packages.list" ]; then
        local core_count
        core_count=$(read_packages_list "$REPO_DIR/packages.list" | wc -l)
        echo "  - Core (packages.list): $core_count packages + dependencies"
    fi
    for plist in "$COMPONENTS_DIR"/*/packages.list; do
        [ -f "$plist" ] || continue
        local comp_name comp_count
        comp_name=$(basename "$(dirname "$plist")")
        comp_count=$(read_packages_list "$plist" | wc -l)
        [ "$comp_count" -eq 0 ] && continue
        echo "  - $comp_name: $comp_count packages + dependencies"
    done
    echo "  - Firefox: 1 package + dependencies (from Mozilla APT repo)"
    echo "  - VS Code: 1 package"
    echo "  - Cloud image: Ubuntu 24.04 minimal (~600MB)"
    echo "  - Ollama: Linux binary for local LLM inference"
    echo ""
    echo "Files generated:"
    echo "  - Packages      (apt package index)"
    echo "  - Packages.gz   (compressed index)"
    echo "  - Release       (repository metadata)"
    echo "  - SHA256SUMS    (integrity verification)"
    echo ""
    echo "Next steps:"
    echo "  1. Recreate the USB with the new packages:"
    echo "     sudo ./create-bootable-usb.sh /path/to/ubuntu.iso /dev/sdX ."
    echo ""
    echo "  2. The USB will now support FULLY OFFLINE installation"
    echo "     No network connection required!"
    echo ""
}

#==============================================================================#
# MAIN
#==============================================================================#

main() {
    echo ""
    echo "==============================================================================="
    echo "  Full Offline Package Download for USB Autoinstall"
    echo "==============================================================================="
    echo ""
    echo "This will download ALL packages required for offline XFCE desktop installation."
    echo "Total download size: ~1.5-2GB"
    echo ""

    check_root

    # Confirm before proceeding
    read -p "Continue with download? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Download cancelled"
        exit 0
    fi

    # Update package lists
    log_info "Updating package lists..."
    apt-get update -qq

    # Setup Docker repository
    setup_docker_repo || log_warning "Docker repository setup failed - Docker packages may not download"

    # Create packages directory
    mkdir -p "$PACKAGES_DIR"
    cd "$PACKAGES_DIR"

    # Download all packages
    download_all_ubuntu_packages
    download_docker_packages
    download_firefox || log_warning "Firefox download failed - will be skipped during offline install"
    download_vscode
    download_cloud_image
    download_ollama || log_warning "Ollama download failed — local AI models won't be available offline"

    # Cleanup and finalize
    cleanup_duplicates
    generate_package_index
    generate_checksums

    # Show summary
    show_summary
}

main "$@"
