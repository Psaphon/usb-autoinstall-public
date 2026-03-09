#!/usr/bin/env bash
#===============================================================================
# Package Integrity Verification Script
#===============================================================================
# Description: Verifies SHA256 checksums of all packages before installation
# Usage: ./verify-packages.sh
# Author: Ephemeral Security Workstation Project
# Version: 1.0.0
#
# This script MUST pass before packages are installed.
# Prevents:
#   - Corrupted USB stick data
#   - Tampered packages
#   - Accidental modifications
#
# Exit codes:
#   0 - All packages verified successfully
#   1 - Verification failed (DO NOT PROCEED WITH INSTALL)
#===============================================================================

set -euo pipefail

#==============================================================================#
# CONSTANTS
#==============================================================================#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PACKAGES_DIR="$SCRIPT_DIR/../packages"
readonly CHECKSUM_FILE="$PACKAGES_DIR/SHA256SUMS"
# Use /var/log if available (more reliable during early boot), fallback to /tmp
if [ -d /var/log ] && [ -w /var/log ]; then
    readonly LOG_FILE="/var/log/package-verification.log"
else
    readonly LOG_FILE="/tmp/package-verification.log"
fi

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

#==============================================================================#
# FUNCTIONS
#==============================================================================#

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

verify_environment() {
    log_info "Verifying environment..."

    # Check if packages directory exists
    if [[ ! -d "$PACKAGES_DIR" ]]; then
        log_error "Packages directory not found: $PACKAGES_DIR"
        return 1
    fi

    # Check if checksum file exists
    if [[ ! -f "$CHECKSUM_FILE" ]]; then
        log_error "Checksum file not found: $CHECKSUM_FILE"
        log_error "Cannot verify package integrity without checksums!"
        return 1
    fi

    # Check if sha256sum is available
    if ! command -v sha256sum &> /dev/null; then
        log_error "sha256sum command not found"
        return 1
    fi

    log_success "Environment verified"
    return 0
}

count_packages() {
    local deb_count
    deb_count=$(find "$PACKAGES_DIR" -name "*.deb" 2>/dev/null | wc -l)
    echo "$deb_count"
}

verify_checksums() {
    log_info "Verifying package checksums..."

    local package_count
    package_count=$(count_packages)

    if [[ $package_count -eq 0 ]]; then
        log_warning "No .deb packages found in $PACKAGES_DIR"
        log_warning "This is OK if packages will be downloaded during install"
        return 0
    fi

    log_info "Found $package_count .deb packages"

    # Change to packages directory for checksum verification
    cd "$PACKAGES_DIR" || return 1

    # Verify checksums
    if sha256sum -c SHA256SUMS 2>&1 | tee -a "$LOG_FILE"; then
        log_success "All package checksums verified successfully!"
        return 0
    else
        log_error "Checksum verification FAILED!"
        log_error "One or more packages have been modified or corrupted"
        log_error "DO NOT PROCEED WITH INSTALLATION"
        return 1
    fi
}

show_summary() {
    local exit_code=$1

    echo ""
    echo "==============================================================================="
    if [[ $exit_code -eq 0 ]]; then
        log_success "Package Verification: PASSED"
        echo "Safe to proceed with installation"
    else
        log_error "Package Verification: FAILED"
        echo "DO NOT PROCEED - Investigate integrity issues"
    fi
    echo "==============================================================================="
    echo "Log file: $LOG_FILE"
    echo ""
}

#==============================================================================#
# MAIN
#==============================================================================#

main() {
    echo ""
    echo "==============================================================================="
    echo "  Package Integrity Verification"
    echo "==============================================================================="
    echo ""

    # Clear old log
    true > "$LOG_FILE"

    # Verify environment
    if ! verify_environment; then
        show_summary 1
        exit 1
    fi

    # Verify checksums
    if ! verify_checksums; then
        show_summary 1
        exit 1
    fi

    show_summary 0
    exit 0
}

main "$@"
