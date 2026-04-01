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
    local original_ip=$2
    local port=$(vagrant port "$host" 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
    if [[ -n "$port" ]]; then
        echo " [+] $host -> 127.0.0.1:$port"
        sed -i "s/ansible_host: $original_ip/ansible_host: 127.0.0.1/g" ../ansible/inventories/production/hosts.yml
        sed -i "/$host:/,/machine_role:/ s/ansible_port: 5986/ansible_port: $port/" ../ansible/inventories/production/hosts.yml
    fi
}

# Fix Linux Machines (SSH 22)
update_lin_host() {
    local host=$1
    local original_ip=$2
    local port=$(vagrant port "$host" 2>/dev/null | grep -E "22 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
    if [[ -n "$port" ]]; then
        echo " [+] $host -> 127.0.0.1:$port"
        sed -i "s/ansible_host: $original_ip/ansible_host: 127.0.0.1/g" ../ansible/inventories/production/hosts.yml
        
        # Inject the ansible_port line if it's missing (Linux entries don't have it by default)
        if ! grep -q "ansible_port: $port" ../ansible/inventories/production/hosts.yml; then
            sed -i "/$host:/a \          ansible_port: $port" ../ansible/inventories/production/hosts.yml
        fi
    fi
}

update_win_host dc01 172.16.50.10
update_win_host fs01 172.16.50.11
update_win_host db01 172.16.50.12
update_win_host app01 172.16.50.13
update_win_host ws01 172.16.50.21
update_win_host ws02 172.16.50.22

update_lin_host dmz-web01 192.168.50.10
update_lin_host dmz-mail01 192.168.50.11
update_lin_host dev-linux01 172.16.50.30
update_lin_host mon01-linux 172.16.50.40

cd ..
echo "[*] Network abstractions bypassed! Forcing Ansible playbook to execute via NAT bindings..."

export ANSIBLE_HOST_KEY_CHECKING=False

# Run only phases 2, 3, and 4
ansible-playbook -i ansible/inventories/production/hosts.yml ansible/site.yml
