#!/bin/bash
# ==============================================================================
# system-maintenance.sh - Linux System Maintenance Script
# Version: 3.0.0
# License: MIT
# Requires: bash 4.0+, Debian/Ubuntu system
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# CONFIGURATION
# ==============================================================================

readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_PID="$$"

# Paths
readonly LOG_DIR="${LOG_DIR:-/var/log/system-maintenance}"
readonly LOG_FILE="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
readonly BACKUP_DIR="/var/backups/system-maintenance"

# Thresholds
readonly CACHE_AGE_DAYS=30
readonly TMP_AGE_DAYS=2
readonly LOG_RETENTION_DAYS=7
readonly LOG_MAX_SIZE="100M"
readonly MIN_REQUIRED_SPACE_GB=5

# Feature flags (can be overridden by CLI)
DRY_RUN=false
ENABLE_FLATPAK=true
ENABLE_SNAP=true
ENABLE_LOGS=true
INTERACTIVE=false
FORCE_REBOOT=false
QUIET=false

# State tracking
declare -A METRICS=(
    [space_before]=0
    [space_after]=0
    [packages_removed]=0
    [orphans_removed]=0
    [cache_cleared_mb]=0
    [logs_cleared_mb]=0
    [errors]=0
)

# ==============================================================================
# TERMINAL COLORS
# ==============================================================================

if [[ -t 1 ]] && command -v tput &>/dev/null; then
    readonly C_RED=$(tput setaf 1)
    readonly C_GREEN=$(tput setaf 2)
    readonly C_YELLOW=$(tput setaf 3)
    readonly C_BLUE=$(tput setaf 4)
    readonly C_CYAN=$(tput setaf 6)
    readonly C_BOLD=$(tput bold)
    readonly C_RESET=$(tput sgr0)
else
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_CYAN=''
    readonly C_BOLD=''
    readonly C_RESET=''
fi

# ==============================================================================
# LOGGING
# ==============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${msg}" >> "${LOG_FILE}"

    if [[ "${QUIET}" == false ]]; then
        case "${level}" in
            INFO)  echo "${C_BLUE}→${C_RESET} ${msg}" ;;
            OK)    echo "${C_GREEN}✓${C_RESET} ${msg}" ;;
            WARN)  echo "${C_YELLOW}⚠${C_RESET} ${msg}" ;;
            ERROR) echo "${C_RED}✗${C_RESET} ${msg}" >&2 ;;
            SKIP)  echo "${C_CYAN}○${C_RESET} ${msg}" ;;
        esac
    fi
}

log_command() {
    local desc="$1"
    shift

    log INFO "Executing: ${desc}"

    if [[ "${DRY_RUN}" == true ]]; then
        log SKIP "[DRY RUN] Would execute: $*"
        return 0
    fi

    if "$@" >> "${LOG_FILE}" 2>&1; then
        log OK "${desc}"
        return 0
    else
        local ret=$?
        log ERROR "${desc} (exit code: ${ret})"
        ((METRICS[errors]++))
        return "${ret}"
    fi
}

# ==============================================================================
# ERROR HANDLING & CLEANUP
# ==============================================================================

cleanup() {
    local exit_code=$?

    if [[ "${exit_code}" -ne 0 ]]; then
        log ERROR "Script failed with exit code ${exit_code}"
    fi

    # Ensure dpkg isn't locked
    if fuser /var/lib/dpkg/lock-frontend &>/dev/null; then
        log WARN "Waiting for dpkg lock to release..."
        sleep 2
    fi

    return "${exit_code}"
}

handle_error() {
    local line="$1"
    local code="$2"
    log ERROR "Error on line ${line}, exit code ${code}"
    cleanup
}

trap 'handle_error ${LINENO} $?' ERR
trap cleanup EXIT INT TERM

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

command_exists() {
    command -v "$1" &>/dev/null
}

is_root() {
    [[ "${EUID}" -eq 0 ]]
}

get_free_space_gb() {
    df -BG / | awk 'NR==2 {print $4}' | tr -d 'G'
}

get_dir_size_mb() {
    local path="$1"
    [[ -d "${path}" ]] || return 0
    du -sm "${path}" 2>/dev/null | awk '{print $1}' || echo 0
}

wait_for_dpkg_lock() {
    local max_wait=300
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend &>/dev/null; do
        if [[ "${waited}" -ge "${max_wait}" ]]; then
            log ERROR "Timeout waiting for dpkg lock"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done

    return 0
}

safe_remove() {
    local path="$1"

    # Sanity checks
    [[ -z "${path}" ]] && return 1
    [[ "${path}" == "/" ]] && return 1
    [[ "${path}" == "/home" ]] && return 1
    [[ "${path}" == "/root" ]] && return 1

    if [[ "${DRY_RUN}" == true ]]; then
        log SKIP "[DRY RUN] Would remove: ${path}"
        return 0
    fi

    if [[ -e "${path}" ]]; then
        rm -rf "${path}" 2>/dev/null || {
            log WARN "Failed to remove: ${path}"
            return 1
        }
    fi

    return 0
}

detect_environment() {
    if [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo "container"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
    elif systemctl is-system-running --quiet 2>/dev/null; then
        if command_exists dpkg && dpkg -l | grep -q ubuntu-desktop; then
            echo "desktop"
        else
            echo "server"
        fi
    else
        echo "unknown"
    fi
}

# ==============================================================================
# VALIDATION
# ==============================================================================

validate_environment() {
    log INFO "Validating environment..."

    # Root check
    if ! is_root; then
        log ERROR "Must be run as root"
        return 1
    fi

    # OS check
    if [[ ! -f /etc/debian_version ]]; then
        log ERROR "This script requires a Debian-based system"
        return 1
    fi

    # Space check
    local free_space=$(get_free_space_gb)
    if [[ "${free_space}" -lt "${MIN_REQUIRED_SPACE_GB}" ]]; then
        log WARN "Low disk space: ${free_space}GB (minimum: ${MIN_REQUIRED_SPACE_GB}GB)"
        if [[ "${INTERACTIVE}" == true ]]; then
            read -rp "Continue anyway? [y/N] " response
            [[ ! "${response}" =~ ^[Yy]$ ]] && return 1
        fi
    fi

    # Network check (non-blocking)
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log WARN "No internet connectivity detected"
    fi

    # Detect environment
    local env=$(detect_environment)
    log INFO "Environment detected: ${env}"

    # Create directories
    mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"

    log OK "Environment validation passed"
    return 0
}

# ==============================================================================
# BACKUP
# ==============================================================================

create_backup() {
    log INFO "Creating package backup..."

    local backup_file="${BACKUP_DIR}/packages_$(date +%Y%m%d_%H%M%S).txt"

    if dpkg --get-selections > "${backup_file}" 2>/dev/null; then
        log OK "Package list backed up to: ${backup_file}"

        # Rotate old backups (keep last 5)
        find "${BACKUP_DIR}" -name "packages_*.txt" -type f | sort -r | tail -n +6 | xargs -r rm
    else
        log WARN "Failed to create package backup"
    fi
}

# ==============================================================================
# MAINTENANCE OPERATIONS
# ==============================================================================

update_package_lists() {
    log INFO "Updating package lists..."

    wait_for_dpkg_lock || return 1

    if log_command "apt update" apt-get update -qq; then
        return 0
    else
        log WARN "Failed to update package lists (continuing anyway)"
        return 0  # Non-critical
    fi
}

remove_unused_packages() {
    log INFO "Checking for unused packages..."

    wait_for_dpkg_lock || return 1

    # Count removable packages
    local count=$(apt-get autoremove --dry-run 2>/dev/null | grep -Po '^\d+(?= .* remove)' || echo "0")

    if [[ "${count}" -eq 0 ]]; then
        log OK "No unused packages found"
        return 0
    fi

    log INFO "Found ${count} unused packages"
    METRICS[packages_removed]=${count}

    log_command "Remove unused packages" apt-get autoremove --purge -y -qq
}

clean_apt_cache() {
    log INFO "Cleaning APT cache..."

    local cache_dir="/var/cache/apt/archives"
    local size_before=$(get_dir_size_mb "${cache_dir}")

    wait_for_dpkg_lock || return 1

    log_command "Clean APT cache" apt-get clean
    log_command "Autoclean APT cache" apt-get autoclean -y

    local size_after=$(get_dir_size_mb "${cache_dir}")
    local cleared=$((size_before - size_after))

    METRICS[cache_cleared_mb]=$((METRICS[cache_cleared_mb] + cleared))

    log OK "APT cache cleaned (freed ${cleared}MB)"
}

remove_orphaned_packages() {
    log INFO "Checking for orphaned packages..."

    # Install deborphan if needed
    if ! command_exists deborphan; then
        log INFO "Installing deborphan..."
        wait_for_dpkg_lock || return 1
        if ! apt-get install -y deborphan -qq >> "${LOG_FILE}" 2>&1; then
            log WARN "Could not install deborphan (skipping)"
            return 0
        fi
    fi

    local orphans=$(deborphan 2>/dev/null)

    if [[ -z "${orphans}" ]]; then
        log OK "No orphaned packages found"
        return 0
    fi

    local count=$(echo "${orphans}" | wc -l)
    log INFO "Found ${count} orphaned packages"
    METRICS[orphans_removed]=${count}

    if [[ "${DRY_RUN}" == true ]]; then
        log SKIP "[DRY RUN] Would remove orphaned packages"
        return 0
    fi

    wait_for_dpkg_lock || return 1

    echo "${orphans}" | xargs -r apt-get purge --auto-remove -y -qq >> "${LOG_FILE}" 2>&1 || {
        log WARN "Some orphaned packages could not be removed"
        return 0
    }

    log OK "Orphaned packages removed"
}

remove_residual_configs() {
    log INFO "Checking for residual configs..."

    local residual=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')

    if [[ -z "${residual}" ]]; then
        log OK "No residual configs found"
        return 0
    fi

    local count=$(echo "${residual}" | wc -l)
    log INFO "Found ${count} residual configs"

    if [[ "${DRY_RUN}" == true ]]; then
        log SKIP "[DRY RUN] Would remove residual configs"
        return 0
    fi

    wait_for_dpkg_lock || return 1

    echo "${residual}" | xargs -r dpkg --purge >> "${LOG_FILE}" 2>&1 || {
        log WARN "Some residual configs could not be removed"
        return 0
    }

    log OK "Residual configs removed"
}

clean_flatpak() {
    [[ "${ENABLE_FLATPAK}" == false ]] && return 0

    if ! command_exists flatpak; then
        log SKIP "Flatpak not installed"
        return 0
    fi

    log INFO "Cleaning Flatpak..."

    log_command "Remove unused Flatpak packages" flatpak uninstall --unused -y || true
    log_command "Repair Flatpak (user)" flatpak repair --user || true
    log_command "Repair Flatpak (system)" flatpak repair || true

    log OK "Flatpak maintenance completed"
}

clean_snap() {
    [[ "${ENABLE_SNAP}" == false ]] && return 0

    if ! command_exists snap; then
        log SKIP "Snap not installed"
        return 0
    fi

    log INFO "Cleaning Snap..."

    if [[ "${DRY_RUN}" == true ]]; then
        local count=$(snap list --all 2>/dev/null | awk '/disabled/{print $1}' | wc -l)
        log SKIP "[DRY RUN] Would remove ${count} disabled snap revisions"
        return 0
    fi

    snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}' | while read -r snapname revision; do
        if [[ -n "${snapname}" && -n "${revision}" ]]; then
            snap remove "${snapname}" --revision="${revision}" >> "${LOG_FILE}" 2>&1 || true
        fi
    done

    log OK "Snap maintenance completed"
}

clean_system_logs() {
    [[ "${ENABLE_LOGS}" == false ]] && return 0

    log INFO "Cleaning system logs..."

    local logs_before=0
    local logs_after=0

    # Journal logs
    if command_exists journalctl; then
        logs_before=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[KMGT]?' | head -1 || echo "0")

        log_command "Vacuum journal by time" journalctl --vacuum-time=${LOG_RETENTION_DAYS}d || true
        log_command "Vacuum journal by size" journalctl --vacuum-size=${LOG_MAX_SIZE} || true

        logs_after=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[KMGT]?' | head -1 || echo "0")
    fi

    # Old log files
    if [[ "${DRY_RUN}" == false ]]; then
        find /var/log -type f \( -name "*.log.*" -o -name "*.gz" \) -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true
    fi

    log OK "System logs cleaned"
}

clean_user_caches() {
    log INFO "Cleaning user caches..."

    # Root cache
    if [[ -d "${HOME}/.cache" ]]; then
        local size_before=$(get_dir_size_mb "${HOME}/.cache")

        if [[ "${DRY_RUN}" == false ]]; then
            find "${HOME}/.cache" -type f -atime +${CACHE_AGE_DAYS} -delete 2>/dev/null || true
            safe_remove "${HOME}/.thumbnails"
        fi

        local size_after=$(get_dir_size_mb "${HOME}/.cache")
        local cleared=$((size_before - size_after))
        METRICS[cache_cleared_mb]=$((METRICS[cache_cleared_mb] + cleared))
    fi

    # User home directories
    for user_home in /home/*; do
        [[ ! -d "${user_home}" ]] && continue

        local username=$(basename "${user_home}")

        if [[ -d "${user_home}/.cache" ]]; then
            local size_before=$(get_dir_size_mb "${user_home}/.cache")

            if [[ "${DRY_RUN}" == false ]]; then
                find "${user_home}/.cache" -type f -atime +${CACHE_AGE_DAYS} -delete 2>/dev/null || true
                safe_remove "${user_home}/.thumbnails"
            fi

            local size_after=$(get_dir_size_mb "${user_home}/.cache")
            local cleared=$((size_before - size_after))

            if [[ "${cleared}" -gt 0 ]]; then
                log OK "Cleaned ${username} cache (${cleared}MB)"
                METRICS[cache_cleared_mb]=$((METRICS[cache_cleared_mb] + cleared))
            fi
        fi
    done

    log OK "User caches cleaned"
}

clean_temp_files() {
    log INFO "Cleaning temporary files..."

    if [[ "${DRY_RUN}" == false ]]; then
        find /tmp -type f -atime +${TMP_AGE_DAYS} -delete 2>/dev/null || true
        find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    fi

    log OK "Temporary files cleaned"
}

clean_misc_caches() {
    log INFO "Cleaning miscellaneous caches..."

    # Man cache
    safe_remove "/var/cache/man/*"

    # Python pip cache
    safe_remove "${HOME}/.cache/pip"
    for user_home in /home/*; do
        safe_remove "${user_home}/.cache/pip"
    done

    # npm cache (if installed)
    if command_exists npm; then
        if [[ "${DRY_RUN}" == false ]]; then
            npm cache clean --force >> "${LOG_FILE}" 2>&1 || true
        fi
    fi

    # Update locate database
    if command_exists updatedb; then
        if [[ "${DRY_RUN}" == false ]]; then
            updatedb >> "${LOG_FILE}" 2>&1 || true
        fi
    fi

    log OK "Miscellaneous caches cleaned"
}

# ==============================================================================
# ORCHESTRATION
# ==============================================================================

run_maintenance() {
    log INFO "Starting system maintenance (version ${SCRIPT_VERSION})"
    log INFO "PID: ${SCRIPT_PID}, Log: ${LOG_FILE}"

    if [[ "${DRY_RUN}" == true ]]; then
        log WARN "DRY RUN MODE - No changes will be made"
    fi

    # Capture initial state
    METRICS[space_before]=$(get_free_space_gb)

    # Execute maintenance tasks
    create_backup
    update_package_lists
    remove_unused_packages
    clean_apt_cache
    remove_orphaned_packages
    remove_residual_configs
    clean_flatpak
    clean_snap
    clean_system_logs
    clean_user_caches
    clean_temp_files
    clean_misc_caches

    # Capture final state
    METRICS[space_after]=$(get_free_space_gb)

    log OK "Maintenance completed"
}

# ==============================================================================
# REPORTING
# ==============================================================================

print_report() {
    local freed=$((METRICS[space_after] - METRICS[space_before]))

    echo ""
    echo "${C_CYAN}═══════════════════════════════════════════════════════════${C_RESET}"
    echo "${C_BOLD}MAINTENANCE REPORT${C_RESET}"
    echo "${C_CYAN}═══════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo "  Space before:       ${METRICS[space_before]}GB"
    echo "  Space after:        ${METRICS[space_after]}GB"
    echo "  Space freed:        ${C_GREEN}${freed}GB${C_RESET}"
    echo ""
    echo "  Packages removed:   ${METRICS[packages_removed]}"
    echo "  Orphans removed:    ${METRICS[orphans_removed]}"
    echo "  Cache cleared:      ${METRICS[cache_cleared_mb]}MB"
    echo "  Errors:             ${METRICS[errors]}"
    echo ""
    echo "  Log file:           ${LOG_FILE}"
    echo "${C_CYAN}═══════════════════════════════════════════════════════════${C_RESET}"
    echo ""

    if [[ "${METRICS[errors]}" -gt 0 ]]; then
        log WARN "Completed with ${METRICS[errors]} error(s). Check log for details."
    fi
}

# ==============================================================================
# CLI INTERFACE
# ==============================================================================

show_usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

System maintenance script for Debian/Ubuntu systems.

OPTIONS:
    -d, --dry-run           Simulate actions without making changes
    -i, --interactive       Ask for confirmation before operations
    -q, --quiet             Suppress console output
    --no-flatpak            Skip Flatpak maintenance
    --no-snap               Skip Snap maintenance
    --no-logs               Skip log cleanup
    --force-reboot          Automatically reboot after completion
    -h, --help              Show this help message
    -v, --version           Show version information

EXAMPLES:
    sudo ${SCRIPT_NAME}                    # Run full maintenance
    sudo ${SCRIPT_NAME} --dry-run          # Preview actions
    sudo ${SCRIPT_NAME} --no-snap          # Skip snap operations

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            --no-flatpak)
                ENABLE_FLATPAK=false
                shift
                ;;
            --no-snap)
                ENABLE_SNAP=false
                shift
                ;;
            --no-logs)
                ENABLE_LOGS=false
                shift
                ;;
            --force-reboot)
                FORCE_REBOOT=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_usage
                exit 1
                ;;
        esac
    done
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    parse_args "$@"

    validate_environment || exit 1

    run_maintenance

    print_report

    # Reboot handling
    if [[ "${FORCE_REBOOT}" == true ]]; then
        log INFO "Rebooting system (forced)..."
        sleep 2
        reboot
    elif [[ "${INTERACTIVE}" == true ]] && [[ "${DRY_RUN}" == false ]]; then
        read -rp "Reboot now? [y/N] " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            log INFO "Rebooting system..."
            sleep 2
            reboot
        fi
    fi

    exit 0
}

main "$@"
