#!/usr/bin/env bash
# =============================================================================
# FORCE DEPLOY OVER VAGRANT NAT TUNNELS
# This script completely bypasses VirtualBox host OS networking bugs
# by automatically scraping Vagrant's NAT forwarded ports and rewriting
# the Ansible inventory to tunnel over localhost.
# =============================================================================

# Install Ansible WinRM dependencies if missing
echo "[*] Ensuring pywinrm is installed for WinRM tunneling..."
pip install pywinrm &>/dev/null || true

cd vagrant
echo "[*] Scraping dynamic NAT ports from Vagrant..."

# Fix Windows Machines (WinRM 5986)
update_win_host() {
    local host=$1
    local port=$(vagrant port "$host" 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
    if [[ -n "$port" ]]; then
        echo " [+] $host -> 127.0.0.1:$port"
        echo "ansible_host: 127.0.0.1" >> "../ansible/host_vars/${host}.yml"
        echo "ansible_port: $port" >> "../ansible/host_vars/${host}.yml"
    fi
}

# Fix Linux Machines (SSH 22)
update_lin_host() {
    local host=$1
    local file_name=$2
    local port=$(vagrant port "$host" 2>/dev/null | grep -E "22 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
    if [[ -n "$port" ]]; then
        echo " [+] $host -> 127.0.0.1:$port"
        # Ensure host_vars file exists
        mkdir -p ../ansible/host_vars
        touch "../ansible/host_vars/${file_name}.yml"
        echo "ansible_host: 127.0.0.1" >> "../ansible/host_vars/${file_name}.yml"
        echo "ansible_port: $port" >> "../ansible/host_vars/${file_name}.yml"
    fi
}

update_win_host dc01
update_win_host fs01
update_win_host db01
update_win_host app01
update_win_host ws01
update_win_host ws02

update_lin_host dmz-web01 dmz-web01
update_lin_host dmz-mail01 dmz-mail01
update_lin_host dev-linux01 dev-linux01
update_lin_host mon01 mon01-linux

cd ..
echo "[*] Network abstractions bypassed! Forcing Ansible playbook to execute via NAT bindings..."

export ANSIBLE_HOST_KEY_CHECKING=False

# Run only phases 2, 3, and 4
ansible-playbook -i ansible/inventories/production/hosts.yml ansible/site.yml
