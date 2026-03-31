#!/usr/bin/env bash
# Prolabs Healthcheck & Auto-Starter

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_DIR="${SCRIPT_DIR}/vagrant"

# Defined array for correct dependency order
VMS=("router" "dmz-web01" "dmz-mail01" "dc01" "fs01" "db01" "app01" "ws01" "ws02" "dev-linux01" "mon01")

get_ip() {
    case "$1" in
        "router") echo "10.10.10.1 (Attacker) | 192.168.50.1 (DMZ) | 172.16.50.1 (Internal)" ;;
        "dmz-web01") echo "192.168.50.10" ;;
        "dmz-mail01") echo "192.168.50.11" ;;
        "dc01") echo "172.16.50.10" ;;
        "fs01") echo "172.16.50.11" ;;
        "db01") echo "172.16.50.12" ;;
        "app01") echo "172.16.50.13" ;;
        "ws01") echo "172.16.50.21" ;;
        "ws02") echo "172.16.50.22" ;;
        "dev-linux01") echo "172.16.50.30" ;;
        "mon01") echo "172.16.50.40" ;;
        *) echo "Unknown" ;;
    esac
}

echo -e "\033[1;36m=================================================================\033[0m"
echo -e "\033[1;36m           Prolabs AD Attack Range Healthcheck & Auto-Start      \033[0m"
echo -e "\033[1;36m=================================================================\033[0m"
echo "Checking status of all 11 Virtual Machines..."
echo ""

cd "${VAGRANT_DIR}"

for vm in "${VMS[@]}"; do
    IP=$(get_ip "$vm")
    
    # Check current status
    STATUS=$(vagrant status "${vm}" --machine-readable 2>/dev/null | grep ",state," | cut -d',' -f4 || echo "unknown")
    
    if [[ "${STATUS}" == "running" ]]; then
        printf "[\033[32mRUNNING\033[0m] %-15s -> IP: %s\n" "${vm}" "${IP}"
    else
        printf "[\033[31mOFFLINE\033[0m] %-15s -> Currently %s. Attempting to start now...\n" "${vm}" "${STATUS}"
        
        # Stream vagrant up output so user doesn't think it's hanging
        vagrant up "${vm}" --no-parallel 
        
        # Verify again
        NEW_STATUS=$(vagrant status "${vm}" --machine-readable 2>/dev/null | grep ",state," | cut -d',' -f4 || echo "unknown")
        if [[ "${NEW_STATUS}" == "running" ]]; then
            echo -ne "\033[1A\033[2K\r" # Clear previous vagrant output end line
            printf "  -> \033[32m[SUCCESS]\033[0m %-11s is now running -> IP: %s\n" "${vm}" "${IP}"
        else
            printf "  -> \033[31m[FAILED]\033[0m  %-11s could not be started. Check above for errors.\n" "${vm}"
        fi
    fi
done

echo ""
echo -e "\033[1;36mHealthcheck Run Complete.\033[0m"
