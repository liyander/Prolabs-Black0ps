#!/usr/bin/env bash
# Start Prolabs Infrastructure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_DIR="${SCRIPT_DIR}/vagrant"

echo -e "\033[1;32m=================================================================\033[0m"
echo -e "\033[1;32m                 Starting Prolabs Environment                     \033[0m"
echo -e "\033[1;32m=================================================================\033[0m"

cd "${VAGRANT_DIR}"

# Run vagrant up which automatically skips already-running VMs
# and safely resumes suspended/stopped VMs
vagrant up --no-parallel

echo ""
echo -e "\033[1;32m[+] All Prolabs VMs have been started successfully!\033[0m"
echo -e "    Run \033[1m./healthcheck.sh\033[0m to view their IP addresses."
