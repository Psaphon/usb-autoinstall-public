#!/usr/bin/env bash
#===============================================================================
# Post-Install Configuration Script
#===============================================================================
# Description: Orchestrates deployment of all components to the installed system.
#              Called by late-commands during autoinstall.
# Usage: Called automatically via chroot from user-data late-commands
# Version: 3.0.0
#
# Component-based architecture:
#   1. Deploys core configs (sysctl hardening, USB eject)
#   2. Iterates over components/ — each with its own install.sh
#   3. Enables systemd services declared by each component
#   4. Installs documentation
#
# Components provide: install.sh, packages.list, services.list
# See components/*/install.sh for per-component deployment logic.
#===============================================================================

# Do NOT use set -euo pipefail — a single component failure should not abort
# the entire deployment. Each component handles its own errors.

#==============================================================================#
# CONSTANTS
#==============================================================================#

readonly AUTOINSTALL_ROOT="/media/autoinstall/usb-autoinstall"
readonly COMPONENTS_DIR="$AUTOINSTALL_ROOT/components"
readonly STORAGE_ROOT="/media/storage"
readonly LOG_FILE="/var/log/baseline-post-install.log"

#==============================================================================#
# FUNCTIONS
#==============================================================================#

log_info() {
    echo "[INFO] $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo "[OK]   $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[ERR]  $*" | tee -a "$LOG_FILE"
}

#==============================================================================#
# CORE DEPLOYMENT
#==============================================================================#

deploy_core_configs() {
    log_info "Applying core system configurations..."
    local src="$AUTOINSTALL_ROOT/files/configs"

    # Sysctl hardening (CIS benchmarks + IPv6 disable)
    if [ -d "$src/sysctl.d" ]; then
        cp "$src/sysctl.d/"* /etc/sysctl.d/ 2>>"$LOG_FILE" || true
        sysctl --system >>"$LOG_FILE" 2>&1 || true
        log_success "Sysctl hardening applied"
    fi
}

deploy_core_systemd() {
    log_info "Deploying core systemd units..."
    local src="$AUTOINSTALL_ROOT/files/systemd"

    if [ -d "$src" ]; then
        for f in "$src"/*.service "$src"/*.timer; do
            [ -f "$f" ] || continue
            cp "$f" /etc/systemd/system/ 2>>"$LOG_FILE" || true
            chmod 644 "/etc/systemd/system/$(basename "$f")"
        done
        log_success "Core systemd units deployed"
    fi
}

deploy_documentation() {
    log_info "Installing documentation..."
    local src="$AUTOINSTALL_ROOT/docs"

    if [ -d "$src" ]; then
        mkdir -p /usr/share/doc/baseline
        cp "$src"/* /usr/share/doc/baseline/ 2>>"$LOG_FILE" || true
        log_success "Documentation installed to /usr/share/doc/baseline/"
    fi
}

#==============================================================================#
# COMPONENT ORCHESTRATION
#==============================================================================#

deploy_components() {
    log_info "Deploying components..."

    if [ ! -d "$COMPONENTS_DIR" ]; then
        log_error "Components directory not found: $COMPONENTS_DIR"
        return 1
    fi

    for component_dir in "$COMPONENTS_DIR"/*/; do
        [ -d "$component_dir" ] || continue
        local name
        name=$(basename "$component_dir")

        if [ -x "$component_dir/install.sh" ] || [ -f "$component_dir/install.sh" ]; then
            log_info "=== Deploying component: $name ==="
            # Export STORAGE_ROOT so components can find Ollama, cloud images, etc.
            if STORAGE_ROOT="$STORAGE_ROOT" bash "$component_dir/install.sh" 2>>"$LOG_FILE"; then
                log_success "Component '$name' deployed"
            else
                log_error "Component '$name' deployment had errors (continuing)"
            fi
        else
            log_info "Skipping component '$name' (no install.sh found)"
        fi
    done
}

enable_services() {
    log_info "Enabling systemd services..."

    # Reload systemd to pick up all newly deployed unit files
    systemctl daemon-reload 2>>"$LOG_FILE" || true

    # Core services (always enabled)
    for svc in ufw fail2ban lightdm; do
        systemctl enable "$svc" >>"$LOG_FILE" 2>&1 || true
    done
    systemctl set-default graphical.target >>"$LOG_FILE" 2>&1 || true

    # Core systemd units from files/systemd/
    for unit in "$AUTOINSTALL_ROOT"/files/systemd/*.service "$AUTOINSTALL_ROOT"/files/systemd/*.timer; do
        [ -f "$unit" ] || continue
        local name
        name=$(basename "$unit")
        systemctl enable "$name" >>"$LOG_FILE" 2>&1 || true
        log_info "  Enabled: $name"
    done

    # Component services (from services.list)
    for component_dir in "$COMPONENTS_DIR"/*/; do
        [ -d "$component_dir" ] || continue
        local name
        name=$(basename "$component_dir")

        if [ -f "$component_dir/services.list" ]; then
            while IFS= read -r service; do
                # Skip comments and empty lines
                [[ "$service" =~ ^#.*$ ]] && continue
                [[ -z "$service" ]] && continue
                service=$(echo "$service" | xargs)  # trim whitespace
                [ -z "$service" ] && continue

                systemctl enable "$service" >>"$LOG_FILE" 2>&1 || true
                log_info "  Enabled ($name): $service"
            done < "$component_dir/services.list"
        fi
    done

    log_success "Service enablement complete"
}

#==============================================================================#
# VERIFICATION
#==============================================================================#

verify_deployment() {
    log_info "Verifying deployment..."

    local failed=0
    local checked=0

    # Check each component deployed its expected files
    for component_dir in "$COMPONENTS_DIR"/*/; do
        [ -d "$component_dir" ] || continue
        local name
        name=$(basename "$component_dir")

        # Check systemd units were deployed
        if [ -d "$component_dir/systemd" ]; then
            for unit in "$component_dir"/systemd/*.service "$component_dir"/systemd/*.timer; do
                [ -f "$unit" ] || continue
                local unit_name
                unit_name=$(basename "$unit")
                checked=$((checked + 1))
                if [ ! -f "/etc/systemd/system/$unit_name" ]; then
                    log_error "MISSING: /etc/systemd/system/$unit_name ($name)"
                    failed=$((failed + 1))
                fi
            done
        fi
    done

    if [ $failed -eq 0 ]; then
        log_success "Verification passed ($checked checks)"
    else
        log_error "Verification: $failed/$checked checks failed"
    fi

    return $failed
}

#==============================================================================#
# MAIN
#==============================================================================#

main() {
    echo "======================================================================" | tee "$LOG_FILE"
    echo "  Ephemeral Security Workstation - Post-Install Deployment" | tee -a "$LOG_FILE"
    echo "  Started: $(date)" | tee -a "$LOG_FILE"
    echo "  Source:  $AUTOINSTALL_ROOT" | tee -a "$LOG_FILE"
    echo "  Version: 3.0.0 (component-based)" | tee -a "$LOG_FILE"
    echo "======================================================================" | tee -a "$LOG_FILE"

    # Verify source directory is accessible
    if [ ! -d "$AUTOINSTALL_ROOT" ]; then
        log_error "AUTOINSTALL_ROOT not accessible: $AUTOINSTALL_ROOT"
        log_error "Expected USB files at this path. Check bind mount."
        exit 1
    fi

    # 1. Core configurations (sysctl hardening)
    deploy_core_configs

    # 2. Core systemd units
    deploy_core_systemd

    # 3. Deploy all components (each has its own install.sh)
    deploy_components

    # 4. Enable all services (core + components)
    enable_services

    # 5. Documentation
    deploy_documentation

    # 6. Verify
    echo "" | tee -a "$LOG_FILE"
    verify_deployment
    local result=$?

    # Create completion marker
    cat > /var/lib/baseline-deployed << EOF
Deployment completed: $(date)
Version: 3.0.0
Method: USB Autoinstall (component-based)
Source: $AUTOINSTALL_ROOT
Components: $(find "$COMPONENTS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)
EOF

    echo "" | tee -a "$LOG_FILE"
    echo "Completed: $(date)" | tee -a "$LOG_FILE"
    echo "Log: $LOG_FILE" | tee -a "$LOG_FILE"
    echo "======================================================================" | tee -a "$LOG_FILE"

    return $result
}

main "$@"
