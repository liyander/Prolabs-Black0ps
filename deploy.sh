#!/usr/bin/env bash
# Usage:
#   ./deploy.sh                  # Full deployment (all phases)
#   ./deploy.sh --phase 1        # Phase 1 only: VM provisioning
#   ./deploy.sh --phase 2        # Phase 2 only: Domain setup
#   ./deploy.sh --phase 3        # Phase 3 only: Vulnerability injection
#   ./deploy.sh --phase 4        # Phase 4 only: CTF flag placement
#   ./deploy.sh --destroy        # Tear down all VMs
#   ./deploy.sh --status         # Show status of all VMs
#   ./deploy.sh --validate       # Validate prerequisites
#   ./deploy.sh --snapshot       # Snapshot all VMs (clean state)
#   ./deploy.sh --restore        # Restore VMs from snapshot
#   ./deploy.sh --vm <name>      # Provision a single VM
#   ./deploy.sh --ansible-only   # Skip Vagrant, run Ansible only
#   ./deploy.sh --help           # Show this help
#
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_DIR="${SCRIPT_DIR}/vagrant"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
PACKER_DIR="${SCRIPT_DIR}/packer"
LOG_DIR="${SCRIPT_DIR}/logs"
SNAPSHOT_NAME="prolab-clean-state"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'

# VM definitions in boot order
ROUTER_VM="router"
DMZ_VMS=("dmz-web01" "dmz-mail01")
DC_VM="dc01"
INTERNAL_WIN_VMS=("fs01" "db01" "app01" "ws01" "ws02")
INTERNAL_LINUX_VMS=("dev-linux01" "mon01")
ALL_VMS=("${ROUTER_VM}" "${DMZ_VMS[@]}" "${DC_VM}" "${INTERNAL_WIN_VMS[@]}" "${INTERNAL_LINUX_VMS[@]}")

# Timing
DEPLOY_START_TIME=""
PHASE_START_TIME=""

# =============================================================================
# Utility Functions
# =============================================================================

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(timestamp)

    case "${level}" in
        INFO)    echo -e "${ts} ${GREEN}[INFO]${NC}    ${msg}" ;;
        WARN)    echo -e "${ts} ${YELLOW}[WARN]${NC}    ${msg}" ;;
        ERROR)   echo -e "${ts} ${RED}[ERROR]${NC}   ${msg}" ;;
        PHASE)   echo -e "${ts} ${MAGENTA}[PHASE]${NC}  ${msg}" ;;
        STEP)    echo -e "${ts} ${CYAN}[STEP]${NC}   ${msg}" ;;
        SUCCESS) echo -e "${ts} ${GREEN}[✓]${NC}      ${msg}" ;;
        FAIL)    echo -e "${ts} ${RED}[✗]${NC}      ${msg}" ;;
        *)       echo -e "${ts} [${level}] ${msg}" ;;
    esac

    # Also write to log file
    echo "${ts} [${level}] ${msg}" >> "${LOG_DIR}/deploy.log" 2>/dev/null || true
}

banner() {
    echo ""
    echo -e "${MAGENTA}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                  ║"
    echo "║   ██████╗ ██████╗  ██████╗ ██╗      █████╗ ██████╗              ║"
    echo "║   ██╔══██╗██╔══██╗██╔═══██╗██║     ██╔══██╗██╔══██╗             ║"
    echo "║   ██████╔╝██████╔╝██║   ██║██║     ███████║██████╔╝             ║"
    echo "║   ██╔═══╝ ██╔══██╗██║   ██║██║     ██╔══██║██╔══██╗             ║"
    echo "║   ██║     ██║  ██║╚██████╔╝███████╗██║  ██║██████╔╝             ║"
    echo "║   ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝            ║"
    echo "║                                                                  ║"
    echo "║          Red Team Infrastructure Deployment                      ║"
    echo "║          Multi-Tier AD Attack Range v1.0                         ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

separator() {
    echo -e "${DIM}──────────────────────────────────────────────────────────────────${NC}"
}

elapsed_time() {
    local start="$1"
    local end
    end=$(date +%s)
    local elapsed=$((end - start))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    if [[ ${hours} -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [[ ${minutes} -gt 0 ]]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

spinner() {
    local pid="$1"
    local msg="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "${pid}" 2>/dev/null; do
        local c="${spin:i++%${#spin}:1}"
        printf "\r  ${CYAN}${c}${NC} ${msg}..."
        sleep 0.1
    done
    printf "\r"
}

confirm() {
    local msg="$1"
    echo -en "${YELLOW}${msg} [y/N]: ${NC}"
    read -r response
    case "${response}" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Prerequisites Validation
# =============================================================================

check_command() {
    local cmd="$1"
    local name="${2:-$1}"
    if command -v "${cmd}" &>/dev/null; then
        local version
        version=$("${cmd}" --version 2>&1 | head -n1) || version="unknown"
        log SUCCESS "${name} found: ${version}"
        return 0
    else
        log FAIL "${name} NOT found"
        return 1
    fi
}

validate_prerequisites() {
    log PHASE "Validating prerequisites..."
    separator

    local errors=0

    # Check required tools
    check_command "vagrant" "Vagrant" || ((errors++))
    check_command "ansible" "Ansible" || ((errors++))
    check_command "ansible-playbook" "Ansible Playbook" || ((errors++))

    # Check optional tools
    check_command "packer" "Packer" || log WARN "Packer not found (needed for building base boxes)"

    # Check Vagrant provider
    log STEP "Checking Vagrant provider..."
    local provider="${VAGRANT_DEFAULT_PROVIDER:-vmware_desktop}"

    if vagrant plugin list 2>/dev/null | grep -q "vagrant-vmware-desktop"; then
        log SUCCESS "Vagrant VMware plugin found"
    elif vagrant plugin list 2>/dev/null | grep -q "vagrant-libvirt"; then
        log SUCCESS "Vagrant libvirt plugin found"
    else
        log WARN "No VMware/libvirt plugin detected. Using default provider."
    fi

    # Check system resources
    log STEP "Checking system resources..."

    local total_ram
    if [[ "$(uname -s)" == "Darwin" ]]; then
        total_ram=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    elif [[ -f /proc/meminfo ]]; then
        total_ram=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
    elif command -v wmic &>/dev/null; then
        total_ram=$(( $(wmic OS get TotalVisibleMemorySize /Value 2>/dev/null | grep -o '[0-9]*') / 1024 / 1024 )) 2>/dev/null || total_ram=0
    else
        total_ram=0
    fi

    if [[ ${total_ram} -gt 0 ]]; then
        if [[ ${total_ram} -ge 64 ]]; then
            log SUCCESS "RAM: ${total_ram}GB (recommended: 64GB+)"
        elif [[ ${total_ram} -ge 48 ]]; then
            log WARN "RAM: ${total_ram}GB (recommended: 64GB+, minimum: 48GB)"
        else
            log FAIL "RAM: ${total_ram}GB (INSUFFICIENT - minimum 48GB required)"
            ((errors++))
        fi
    else
        log WARN "Unable to detect RAM amount"
    fi

    # Check available disk space
    local available_disk
    if command -v df &>/dev/null; then
        available_disk=$(df -BG "${SCRIPT_DIR}" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G') || available_disk=0
        if [[ ${available_disk} -ge 200 ]]; then
            log SUCCESS "Disk: ${available_disk}GB available (recommended: 200GB+)"
        elif [[ ${available_disk} -ge 150 ]]; then
            log WARN "Disk: ${available_disk}GB available (recommended: 200GB+)"
        elif [[ ${available_disk} -ge 70 ]]; then
            log WARN "Disk: ${available_disk}GB available (Low space, but feasible with Linked Clones!)"
        else
            log FAIL "Disk: ${available_disk}GB available (INSUFFICIENT - need 70GB+)"
            ((errors++))
        fi
    fi

    # Check CPU cores
    local cpu_cores
    if [[ "$(uname -s)" == "Darwin" ]]; then
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null) || cpu_cores=0
    elif [[ -f /proc/cpuinfo ]]; then
        cpu_cores=$(nproc 2>/dev/null) || cpu_cores=$(grep -c processor /proc/cpuinfo)
    else
        cpu_cores=$(nproc 2>/dev/null) || cpu_cores=0
    fi

    if [[ ${cpu_cores} -gt 0 ]]; then
        if [[ ${cpu_cores} -ge 12 ]]; then
            log SUCCESS "CPU: ${cpu_cores} cores (recommended: 12+)"
        elif [[ ${cpu_cores} -ge 8 ]]; then
            log WARN "CPU: ${cpu_cores} cores (recommended: 12+)"
        else
            log FAIL "CPU: ${cpu_cores} cores (INSUFFICIENT - need 8+ cores)"
            ((errors++))
        fi
    fi

    # Check Ansible collections
    log STEP "Checking Ansible collections..."
    local required_collections=("community.windows" "ansible.windows" "community.mysql")
    for collection in "${required_collections[@]}"; do
        if ansible-galaxy collection list 2>/dev/null | grep -q "${collection}"; then
            log SUCCESS "Ansible collection: ${collection}"
        else
            log WARN "Missing collection: ${collection} (will attempt install)"
        fi
    done

    separator

    if [[ ${errors} -gt 0 ]]; then
        log ERROR "${errors} critical prerequisite(s) missing. Please resolve before deployment."
        return 1
    else
        log SUCCESS "All critical prerequisites met!"
        return 0
    fi
}

# =============================================================================
# Ansible Collection Installation
# =============================================================================

install_ansible_collections() {
    log STEP "Installing required Ansible collections..."

    ansible-galaxy collection install community.windows --force 2>&1 | tail -1
    ansible-galaxy collection install ansible.windows --force 2>&1 | tail -1
    ansible-galaxy collection install community.mysql --force 2>&1 | tail -1
    ansible-galaxy collection install community.general --force 2>&1 | tail -1

    log SUCCESS "Ansible collections installed"
}

# =============================================================================
# Phase 1: VM Provisioning (Vagrant)
# =============================================================================

provision_vm() {
    local vm_name="$1"
    local phase_start
    phase_start=$(date +%s)

    log STEP "Provisioning VM: ${BOLD}${vm_name}${NC}"

    if vagrant status "${vm_name}" 2>/dev/null | grep -q "running"; then
        log INFO "${vm_name} is already running, re-provisioning..."
        (cd "${VAGRANT_DIR}" && vagrant provision "${vm_name}") \
            >> "${LOG_DIR}/${vm_name}.log" 2>&1 || {
            log FAIL "Re-provisioning ${vm_name} failed (see logs/${vm_name}.log)"
            return 1
        }
    else
        (cd "${VAGRANT_DIR}" && vagrant up "${vm_name}" --no-parallel) \
            >> "${LOG_DIR}/${vm_name}.log" 2>&1 || {
            log FAIL "Provisioning ${vm_name} failed (see logs/${vm_name}.log)"
            return 1
        }
    fi

    local elapsed
    elapsed=$(elapsed_time "${phase_start}")
    log SUCCESS "${vm_name} provisioned successfully (${elapsed})"
    return 0
}

phase1_provision_vms() {
    PHASE_START_TIME=$(date +%s)
    log PHASE "${BOLD}Phase 1: Core Routing & VM Provisioning${NC}"
    separator

    local failed=0

    # ---- Step 1: Router (must come first) ----
    log INFO "${WHITE}[1/4] Provisioning pfSense Router...${NC}"
    provision_vm "${ROUTER_VM}" || ((failed++))

    # ---- Step 2: DMZ VMs ----
    log INFO "${WHITE}[2/4] Provisioning DMZ Network VMs...${NC}"
    for vm in "${DMZ_VMS[@]}"; do
        provision_vm "${vm}" || ((failed++))
    done

    # ---- Step 3: Domain Controller (must come before other internal Windows) ----
    log INFO "${WHITE}[3/4] Provisioning Domain Controller...${NC}"
    provision_vm "${DC_VM}" || ((failed++))

    # ---- Step 4: Internal VMs ----
    log INFO "${WHITE}[4/4] Provisioning Internal Network VMs...${NC}"
    for vm in "${INTERNAL_WIN_VMS[@]}"; do
        provision_vm "${vm}" || ((failed++))
    done
    for vm in "${INTERNAL_LINUX_VMS[@]}"; do
        provision_vm "${vm}" || ((failed++))
    done

    separator
    local elapsed
    elapsed=$(elapsed_time "${PHASE_START_TIME}")

    if [[ ${failed} -eq 0 ]]; then
        log SUCCESS "Phase 1 complete: All ${#ALL_VMS[@]} VMs provisioned (${elapsed})"
    else
        log ERROR "Phase 1 complete with ${failed} failure(s) (${elapsed})"
        log WARN "Review logs in ${LOG_DIR}/ for details"
    fi

    return ${failed}
}

# =============================================================================
# Phase 2: Domain Setup (Ansible)
# =============================================================================

run_ansible_playbook() {
    local tags="$1"
    local description="$2"
    local extra_args="${3:-}"
    local phase_start
    phase_start=$(date +%s)

    log STEP "Running: ${description}"

    local cmd="ansible-playbook -i inventories/production/hosts.yml site.yml --tags ${tags}"
    if [[ -n "${extra_args}" ]]; then
        cmd="${cmd} ${extra_args}"
    fi

    (cd "${ANSIBLE_DIR}" && eval "${cmd}") \
        >> "${LOG_DIR}/ansible-${tags//,/-}.log" 2>&1 || {
        log FAIL "${description} failed (see logs/ansible-${tags//,/-}.log)"
        return 1
    }

    local elapsed
    elapsed=$(elapsed_time "${phase_start}")
    log SUCCESS "${description} complete (${elapsed})"
    return 0
}

phase2_domain_setup() {
    PHASE_START_TIME=$(date +%s)
    log PHASE "${BOLD}Phase 2: Domain Setup & AD Configuration${NC}"
    separator

    local failed=0

    # Wait for DC to be reachable
    log STEP "Waiting for Domain Controller to be reachable..."
    local retries=0
    while ! ansible -i "${ANSIBLE_DIR}/inventories/production/hosts.yml" dc01 -m win_ping &>/dev/null; do
        ((retries++))
        if [[ ${retries} -ge 30 ]]; then
            log ERROR "Domain Controller not reachable after 30 attempts"
            return 1
        fi
        log INFO "Waiting for DC01... (attempt ${retries}/30)"
        sleep 10
    done
    log SUCCESS "DC01 is reachable"

    # Step 2a: Common configuration
    run_ansible_playbook "common" "Common configuration (all hosts)" || ((failed++))

    # Step 2b: Promote DC01
    run_ansible_playbook "dc" "Domain Controller promotion (DC01)" || ((failed++))

    # Wait for DC to come back after promotion reboot
    log STEP "Waiting for DC01 post-promotion reboot..."
    sleep 120
    retries=0
    while ! ansible -i "${ANSIBLE_DIR}/inventories/production/hosts.yml" dc01 -m win_ping &>/dev/null; do
        ((retries++))
        if [[ ${retries} -ge 30 ]]; then
            log ERROR "DC01 not reachable after promotion"
            return 1
        fi
        sleep 15
    done
    log SUCCESS "DC01 online post-promotion"

    # Step 2c: Populate AD
    run_ansible_playbook "ad-pop" "AD population (users, groups, OUs)" || ((failed++))

    # Step 2d: Domain join all Windows machines
    run_ansible_playbook "domain-join" "Domain join (servers + workstations)" || ((failed++))

    # Wait for domain-joined machines to reboot
    log INFO "Waiting 90s for domain-joined machines to stabilize..."
    sleep 90

    # Step 2e: Install AD CS
    run_ansible_playbook "adcs" "AD Certificate Services installation" || ((failed++))

    # Step 2f: Configure Kerberoasting SPNs
    run_ansible_playbook "kerberoast" "Kerberoasting SPN configuration" || ((failed++))

    # Step 2g: Configure Constrained Delegation
    run_ansible_playbook "delegation" "Constrained Delegation setup" || ((failed++))

    separator
    local elapsed
    elapsed=$(elapsed_time "${PHASE_START_TIME}")

    if [[ ${failed} -eq 0 ]]; then
        log SUCCESS "Phase 2 complete: Domain fully configured (${elapsed})"
    else
        log ERROR "Phase 2 complete with ${failed} failure(s) (${elapsed})"
    fi

    return ${failed}
}

# =============================================================================
# Phase 3: Vulnerability Injection
# =============================================================================

phase3_vuln_injection() {
    PHASE_START_TIME=$(date +%s)
    log PHASE "${BOLD}Phase 3: Vulnerability Injection${NC}"
    separator

    local failed=0

    # DMZ vulnerabilities
    log INFO "${WHITE}[DMZ] Injecting DMZ vulnerabilities...${NC}"
    run_ansible_playbook "vuln-cms" "Vulnerable CMS on DMZ-WEB01" || ((failed++))
    run_ansible_playbook "mail" "Mail server on DMZ-MAIL01" || ((failed++))

    # Internal Linux vulnerabilities
    log INFO "${WHITE}[Internal Linux] Injecting Linux vulnerabilities...${NC}"
    run_ansible_playbook "git" "Exposed Git repo on DEV-LINUX01" || ((failed++))
    run_ansible_playbook "monitoring" "Monitoring + LDAP creds on MON01" || ((failed++))

    # Internal Windows vulnerabilities
    log INFO "${WHITE}[Internal Windows] Injecting Windows vulnerabilities...${NC}"
    run_ansible_playbook "winrm,unquoted" "WinRM + Unquoted Path on WS01" || ((failed++))
    run_ansible_playbook "spooler" "Print Spooler on FS01" || ((failed++))
    run_ansible_playbook "smb" "SMB Signing disabled on WS01/APP01" || ((failed++))
    run_ansible_playbook "mssql" "MSSQL + xp_cmdshell on DB01" || ((failed++))

    separator
    local elapsed
    elapsed=$(elapsed_time "${PHASE_START_TIME}")

    if [[ ${failed} -eq 0 ]]; then
        log SUCCESS "Phase 3 complete: All vulnerabilities injected (${elapsed})"
    else
        log ERROR "Phase 3 complete with ${failed} failure(s) (${elapsed})"
    fi

    return ${failed}
}

# =============================================================================
# Phase 4: CTF Flag Placement
# =============================================================================

phase4_ctf_flags() {
    PHASE_START_TIME=$(date +%s)
    log PHASE "${BOLD}Phase 4: CTF Flag Placement${NC}"
    separator

    local failed=0

    run_ansible_playbook "flags" "CTF flag distribution (all machines)" || ((failed++))

    separator
    local elapsed
    elapsed=$(elapsed_time "${PHASE_START_TIME}")

    if [[ ${failed} -eq 0 ]]; then
        log SUCCESS "Phase 4 complete: 17 flags distributed across 10 machines (${elapsed})"
        echo ""
        echo -e "  ${GREEN}┌─────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${GREEN}│  Flags placed:                                          │${NC}"
        echo -e "  ${GREEN}│    • 7 x user.txt  (user-level access)                  │${NC}"
        echo -e "  ${GREEN}│    • 10 x root.txt (root/admin access)                  │${NC}"
        echo -e "  ${GREEN}│    • 10 machines total                                  │${NC}"
        echo -e "  ${GREEN}└─────────────────────────────────────────────────────────┘${NC}"
    else
        log ERROR "Phase 4 had ${failed} failure(s) (${elapsed})"
    fi

    return ${failed}
}

# =============================================================================
# Infrastructure Management Commands
# =============================================================================

show_status() {
    log PHASE "Infrastructure Status"
    separator

    echo ""
    echo -e "  ${BOLD}VM Status:${NC}"
    echo ""

    (cd "${VAGRANT_DIR}" && vagrant status) 2>/dev/null || {
        log WARN "Unable to query VM status. Are VMs provisioned?"
    }

    separator

    echo ""
    echo -e "  ${BOLD}Network Map:${NC}"
    echo ""
    echo -e "  ${CYAN}Attacker Network (10.10.10.x)${NC}"
    echo -e "    └── Kali Attacker (your machine)"
    echo ""
    echo -e "  ${YELLOW}DMZ Network (192.168.50.x)${NC}"
    echo -e "    ├── DMZ-WEB01   192.168.50.10  (Vulnerable CMS)"
    echo -e "    └── DMZ-MAIL01  192.168.50.11  (Mail/Pivot)"
    echo ""
    echo -e "  ${RED}Internal Network (172.16.50.x - corp.local)${NC}"
    echo -e "    ├── DC01        172.16.50.10      (Domain Controller)"
    echo -e "    ├── FS01        172.16.50.11      (File Server)"
    echo -e "    ├── DB01        172.16.50.12      (Database Server)"
    echo -e "    ├── APP01       172.16.50.13      (App Server)"
    echo -e "    ├── WS01        172.16.50.21      (Workstation)"
    echo -e "    ├── WS02        172.16.50.22      (Workstation)"
    echo -e "    ├── DEV-LNX01   172.16.50.30      (Dev Server)"
    echo -e "    └── MON01       172.16.50.40      (Monitoring)"
    echo ""

    separator

    echo ""
    echo -e "  ${BOLD}Routing Rules:${NC}"
    echo -e "    ${GREEN}✅${NC} Attacker (10.10.10.x)  →  DMZ (192.168.50.x)"
    echo -e "    ${RED}❌${NC} Attacker (10.10.10.x)  →  Internal (172.16.50.x)  ${RED}[BLOCKED]${NC}"
    echo -e "    ${GREEN}✅${NC} DMZ (192.168.50.x)     →  Internal (172.16.50.x)  ${DIM}[Specific Ports]${NC}"
    echo ""
}

destroy_infrastructure() {
    log PHASE "Destroying Infrastructure"
    separator

    if ! confirm "This will DESTROY all VMs and data. Are you sure?"; then
        log INFO "Destruction cancelled."
        return 0
    fi

    log WARN "Destroying all VMs..."
    (cd "${VAGRANT_DIR}" && vagrant destroy -f) 2>&1 | tee -a "${LOG_DIR}/destroy.log"

    log SUCCESS "All VMs destroyed"
}

snapshot_vms() {
    log PHASE "Creating Snapshots"
    separator

    local failed=0

    for vm in "${ALL_VMS[@]}"; do
        log STEP "Snapshotting ${vm}..."
        (cd "${VAGRANT_DIR}" && vagrant snapshot save "${vm}" "${SNAPSHOT_NAME}" --force) \
            >> "${LOG_DIR}/snapshot.log" 2>&1 || {
            log FAIL "Snapshot failed for ${vm}"
            ((failed++))
        }
        log SUCCESS "Snapshot created: ${vm}"
    done

    if [[ ${failed} -eq 0 ]]; then
        log SUCCESS "All VMs snapshotted as '${SNAPSHOT_NAME}'"
    else
        log ERROR "${failed} snapshot(s) failed"
    fi
}

restore_vms() {
    log PHASE "Restoring from Snapshots"
    separator

    if ! confirm "Restore all VMs to '${SNAPSHOT_NAME}'? Current state will be lost."; then
        return 0
    fi

    local failed=0

    for vm in "${ALL_VMS[@]}"; do
        log STEP "Restoring ${vm}..."
        (cd "${VAGRANT_DIR}" && vagrant snapshot restore "${vm}" "${SNAPSHOT_NAME}") \
            >> "${LOG_DIR}/restore.log" 2>&1 || {
            log FAIL "Restore failed for ${vm}"
            ((failed++))
        }
        log SUCCESS "Restored: ${vm}"
    done

    if [[ ${failed} -eq 0 ]]; then
        log SUCCESS "All VMs restored to '${SNAPSHOT_NAME}'"
    else
        log ERROR "${failed} restore(s) failed"
    fi
}

provision_single_vm() {
    local vm_name="$1"

    # Validate VM name
    local found=false
    for vm in "${ALL_VMS[@]}"; do
        if [[ "${vm}" == "${vm_name}" ]]; then
            found=true
            break
        fi
    done

    if [[ "${found}" != "true" ]]; then
        log ERROR "Unknown VM: ${vm_name}"
        echo -e "  Available VMs: ${ALL_VMS[*]}"
        return 1
    fi

    log PHASE "Provisioning Single VM: ${vm_name}"
    separator
    provision_vm "${vm_name}"
}

# =============================================================================
# Post-Deployment Validation
# =============================================================================

post_deploy_validation() {
    log PHASE "${BOLD}Post-Deployment Validation${NC}"
    separator

    local checks_passed=0
    local checks_failed=0

    # Check VM status
    log STEP "Verifying all VMs are running..."
    for vm in "${ALL_VMS[@]}"; do
        if (cd "${VAGRANT_DIR}" && vagrant status "${vm}" 2>/dev/null) | grep -q "running"; then
            log SUCCESS "${vm}: running"
            ((checks_passed++))
        else
            log FAIL "${vm}: NOT running"
            ((checks_failed++))
        fi
    done

    # Check network connectivity
    log STEP "Verifying network connectivity..."

    # Test DMZ connectivity
    for ip in "192.168.50.10" "192.168.50.11"; do
        if ping -c 1 -W 2 "${ip}" &>/dev/null; then
            log SUCCESS "DMZ reachable: ${ip}"
            ((checks_passed++))
        else
            log WARN "DMZ may not be reachable from host: ${ip}"
        fi
    done

    # Test Ansible connectivity
    log STEP "Verifying Ansible connectivity..."
    if (cd "${ANSIBLE_DIR}" && ansible all -m ping --one-line 2>/dev/null) | grep -c "SUCCESS" | grep -q "[0-9]"; then
        local reachable
        reachable=$((cd "${ANSIBLE_DIR}" && ansible all -m ping --one-line 2>/dev/null) | grep -c "SUCCESS")
        log SUCCESS "Ansible can reach ${reachable} hosts"
        ((checks_passed++))
    else
        log WARN "Ansible connectivity issues detected"
    fi

    separator
    echo ""
    echo -e "  ${BOLD}Validation Summary:${NC}"
    echo -e "    ${GREEN}Passed:${NC} ${checks_passed}"
    echo -e "    ${RED}Failed:${NC} ${checks_failed}"
    echo ""
}

# =============================================================================
# Full Deployment
# =============================================================================

full_deploy() {
    DEPLOY_START_TIME=$(date +%s)

    banner

    echo -e "  ${BOLD}Deployment Configuration:${NC}"
    echo -e "    Provider:    ${CYAN}${VAGRANT_DEFAULT_PROVIDER:-vmware_desktop}${NC}"
    echo -e "    VMs:         ${CYAN}${#ALL_VMS[@]} machines${NC}"
    echo -e "    Domain:      ${CYAN}corp.local${NC}"
    echo -e "    Networks:    ${CYAN}3 (Attacker/DMZ/Internal)${NC}"
    echo -e "    Log Dir:     ${CYAN}${LOG_DIR}${NC}"
    echo ""

    separator

    if ! confirm "Deploy the complete Prolab infrastructure?"; then
        log INFO "Deployment cancelled."
        exit 0
    fi

    # Create log directory
    mkdir -p "${LOG_DIR}"
    echo "Deployment started: $(timestamp)" > "${LOG_DIR}/deploy.log"

    # Prerequisites
    validate_prerequisites || {
        log ERROR "Prerequisites check failed. Aborting."
        exit 1
    }

    # Install Ansible collections
    install_ansible_collections

    echo ""
    separator

    # ---- Phase 1: VM Provisioning ----
    phase1_provision_vms || {
        log WARN "Phase 1 had failures. Continuing to Phase 2..."
    }

    echo ""

    # ---- Phase 2: Domain Setup ----
    phase2_domain_setup || {
        log WARN "Phase 2 had failures. Continuing to Phase 3..."
    }

    echo ""

    # ---- Phase 3: Vulnerability Injection ----
    phase3_vuln_injection || {
        log WARN "Phase 3 had failures. Continuing to Phase 4..."
    }

    echo ""

    # ---- Phase 4: CTF Flags ----
    phase4_ctf_flags || {
        log WARN "Phase 4 had failures."
    }

    echo ""

    # ---- Post-Deployment ----
    post_deploy_validation

    # ---- Create clean snapshot ----
    if confirm "Create a clean-state snapshot of all VMs?"; then
        snapshot_vms
    fi

    # ---- Final Summary ----
    local total_elapsed
    total_elapsed=$(elapsed_time "${DEPLOY_START_TIME}")

    echo ""
    separator
    echo ""
    echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}${BOLD}║                DEPLOYMENT COMPLETE                           ║${NC}"
    echo -e "  ${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  Total Time:  ${CYAN}${total_elapsed}${NC}                                      ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  VMs:         ${CYAN}${#ALL_VMS[@]} machines deployed${NC}                       ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  Domain:      ${CYAN}corp.local (CORP)${NC}                              ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  Flags:       ${CYAN}17 flags across 10 machines${NC}                    ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  Logs:        ${CYAN}${LOG_DIR}/${NC}                                    ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}                                                              ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  ${YELLOW}Start attacking from the Attacker Network (10.10.10.x)${NC}      ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  ${YELLOW}Target: DMZ-WEB01 at 192.168.50.10${NC}                         ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}                                                              ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}  ${DIM}Attack flow guide: docs/attack-flow.md${NC}                      ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}                                                              ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================================
# Ansible-Only Mode
# =============================================================================

ansible_only() {
    DEPLOY_START_TIME=$(date +%s)

    banner
    log PHASE "Ansible-Only Mode (skipping Vagrant provisioning)"
    separator

    install_ansible_collections

    phase2_domain_setup || log WARN "Phase 2 had failures"
    echo ""
    phase3_vuln_injection || log WARN "Phase 3 had failures"
    echo ""
    phase4_ctf_flags || log WARN "Phase 4 had failures"

    local total_elapsed
    total_elapsed=$(elapsed_time "${DEPLOY_START_TIME}")
    log SUCCESS "Ansible-only deployment complete (${total_elapsed})"
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    banner
    echo -e "  ${BOLD}Usage:${NC} ./deploy.sh [OPTIONS]"
    echo ""
    echo -e "  ${BOLD}Options:${NC}"
    echo -e "    ${CYAN}(no args)${NC}            Full deployment (all 4 phases)"
    echo -e "    ${CYAN}--phase <1-4>${NC}        Run a specific phase only"
    echo -e "    ${CYAN}--validate${NC}           Check all prerequisites"
    echo -e "    ${CYAN}--status${NC}             Show VM status and network map"
    echo -e "    ${CYAN}--vm <name>${NC}          Provision a single VM"
    echo -e "    ${CYAN}--ansible-only${NC}       Run Ansible phases only (2-4)"
    echo -e "    ${CYAN}--snapshot${NC}           Create clean-state snapshots"
    echo -e "    ${CYAN}--restore${NC}            Restore VMs from snapshots"
    echo -e "    ${CYAN}--destroy${NC}            Tear down all VMs"
    echo -e "    ${CYAN}--help${NC}               Show this help message"
    echo ""
    echo -e "  ${BOLD}Phases:${NC}"
    echo -e "    ${MAGENTA}Phase 1:${NC} VM Provisioning (Vagrant)"
    echo -e "      └── Router → DMZ VMs → DC01 → Internal VMs"
    echo -e "    ${MAGENTA}Phase 2:${NC} Domain Setup (Ansible)"
    echo -e "      └── DC Promo → AD Population → Domain Join → ADCS → SPNs → Delegation"
    echo -e "    ${MAGENTA}Phase 3:${NC} Vulnerability Injection (Ansible)"
    echo -e "      └── CMS → Mail → Git → Monitoring → WinRM → Spooler → SMB → MSSQL"
    echo -e "    ${MAGENTA}Phase 4:${NC} CTF Flag Placement (Ansible)"
    echo -e "      └── 17 flags across 10 machines"
    echo ""
    echo -e "  ${BOLD}Available VMs:${NC}"
    echo -e "    router, dmz-web01, dmz-mail01, dc01, fs01, db01, app01,"
    echo -e "    ws01, ws02, dev-linux01, mon01"
    echo ""
    echo -e "  ${BOLD}Examples:${NC}"
    echo -e "    ${DIM}./deploy.sh                    # Deploy everything${NC}"
    echo -e "    ${DIM}./deploy.sh --phase 1          # Provision VMs only${NC}"
    echo -e "    ${DIM}./deploy.sh --phase 3          # Inject vulns only${NC}"
    echo -e "    ${DIM}./deploy.sh --vm dc01          # Provision DC01 only${NC}"
    echo -e "    ${DIM}./deploy.sh --destroy          # Tear it all down${NC}"
    echo ""
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    # Create log directory
    mkdir -p "${LOG_DIR}" 2>/dev/null || true

    # Parse arguments
    case "${1:-}" in
        --help|-h)
            show_help
            ;;
        --validate)
            banner
            validate_prerequisites
            ;;
        --status)
            banner
            show_status
            ;;
        --phase)
            banner
            mkdir -p "${LOG_DIR}"
            case "${2:-}" in
                1) phase1_provision_vms ;;
                2) install_ansible_collections && phase2_domain_setup ;;
                3) install_ansible_collections && phase3_vuln_injection ;;
                4) install_ansible_collections && phase4_ctf_flags ;;
                *)
                    log ERROR "Invalid phase: ${2:-<empty>}. Use 1, 2, 3, or 4."
                    exit 1
                    ;;
            esac
            ;;
        --vm)
            banner
            mkdir -p "${LOG_DIR}"
            if [[ -z "${2:-}" ]]; then
                log ERROR "Specify a VM name. Example: ./deploy.sh --vm dc01"
                exit 1
            fi
            provision_single_vm "$2"
            ;;
        --ansible-only)
            ansible_only
            ;;
        --destroy)
            banner
            destroy_infrastructure
            ;;
        --snapshot)
            banner
            snapshot_vms
            ;;
        --restore)
            banner
            restore_vms
            ;;
        "")
            full_deploy
            ;;
        *)
            log ERROR "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
