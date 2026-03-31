#!/usr/bin/env bash
# Stop Prolabs Infrastructure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_DIR="${SCRIPT_DIR}/vagrant"

echo -e "\033[1;33m=================================================================\033[0m"
echo -e "\033[1;33m                 Stopping Prolabs Environment                     \033[0m"
echo -e "\033[1;33m=================================================================\033[0m"
echo "Sending graceful shutdown signals to all 11 Virtual Machines..."
echo "(This may take a minute or two to safely power down Windows services)"
echo ""

cd "${VAGRANT_DIR}"

# Run vagrant halt to cleanly shut down the guest operating systems
vagrant halt

echo ""
echo -e "\033[1;32m[+] Prolabs infrastructure has been gracefully shut down.\033[0m"
echo -e "    Your progress and data is saved. Run \033[1m./start.sh\033[0m to resume."
