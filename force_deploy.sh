#!/usr/bin/env bash
# =============================================================================
# FORCE DEPLOY OVER VAGRANT NAT TUNNELS
# This script completely bypasses VirtualBox host OS networking bugs
# by automatically scraping Vagrant's NAT forwarded ports and rendering
# a standalone Ansible localhost INI inventory file.
# =============================================================================

echo "[*] Ensuring pywinrm is installed for WinRM tunneling..."
pip install pywinrm &>/dev/null || true

cd vagrant
echo "[*] Scraping dynamic NAT ports from Vagrant..."

# Pull WinRM Ports
DC01_PORT=$(vagrant port dc01 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
FS01_PORT=$(vagrant port fs01 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
DB01_PORT=$(vagrant port db01 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
APP01_PORT=$(vagrant port app01 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
WS01_PORT=$(vagrant port ws01 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
WS02_PORT=$(vagrant port ws02 2>/dev/null | grep -E "5986 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')

# Pull SSH Ports
WEB_PORT=$(vagrant port dmz-web01 2>/dev/null | grep -E "22 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
MAIL_PORT=$(vagrant port dmz-mail01 2>/dev/null | grep -E "22 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
DEV_PORT=$(vagrant port dev-linux01 2>/dev/null | grep -E "22 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')
MON_PORT=$(vagrant port mon01 2>/dev/null | grep -E "22 \(guest\)" | awk '{print $4}' | sed 's/(host)//' | tr -d ' \r')

cd ..
cat <<EOF > localhosts.ini
[all:vars]
ansible_user=vagrant
ansible_password=vagrant
domain_name=corp.local
domain_netbios=CORP
domain_admin_password="P@ssw0rd!2024"
domain_controller_ip=172.16.50.10
dns_server=172.16.50.10

[dmz]
dmz-web01 ansible_host=127.0.0.1 ansible_port=$WEB_PORT ansible_connection=ssh ansible_become=true ansible_become_method=sudo machine_role=webserver cms_type=wordpress
dmz-mail01 ansible_host=127.0.0.1 ansible_port=$MAIL_PORT ansible_connection=ssh ansible_become=true ansible_become_method=sudo machine_role=mailserver

[internal_linux]
dev-linux01 ansible_host=127.0.0.1 ansible_port=$DEV_PORT ansible_connection=ssh ansible_become=true ansible_become_method=sudo machine_role=devserver
mon01-linux ansible_host=127.0.0.1 ansible_port=$MON_PORT ansible_connection=ssh ansible_become=true ansible_become_method=sudo machine_role=monitoring

[domain_controllers]
dc01 ansible_host=127.0.0.1 ansible_port=$DC01_PORT ansible_connection=winrm ansible_winrm_transport=ntlm ansible_winrm_server_cert_validation=ignore ansible_winrm_scheme=https machine_role=domain_controller

[windows_servers]
fs01 ansible_host=127.0.0.1 ansible_port=$FS01_PORT ansible_connection=winrm ansible_winrm_transport=ntlm ansible_winrm_server_cert_validation=ignore ansible_winrm_scheme=https machine_role=file_server
db01 ansible_host=127.0.0.1 ansible_port=$DB01_PORT ansible_connection=winrm ansible_winrm_transport=ntlm ansible_winrm_server_cert_validation=ignore ansible_winrm_scheme=https machine_role=database_server
app01 ansible_host=127.0.0.1 ansible_port=$APP01_PORT ansible_connection=winrm ansible_winrm_transport=ntlm ansible_winrm_server_cert_validation=ignore ansible_winrm_scheme=https machine_role=app_server

[windows_workstations]
ws01 ansible_host=127.0.0.1 ansible_port=$WS01_PORT ansible_connection=winrm ansible_winrm_transport=ntlm ansible_winrm_server_cert_validation=ignore ansible_winrm_scheme=https machine_role=workstation
ws02 ansible_host=127.0.0.1 ansible_port=$WS02_PORT ansible_connection=winrm ansible_winrm_transport=ntlm ansible_winrm_server_cert_validation=ignore ansible_winrm_scheme=https machine_role=workstation_delegation

[linux:children]
dmz
internal_linux

[windows:children]
domain_controllers
windows_servers
windows_workstations

[internal:children]
domain_controllers
windows_servers
windows_workstations
internal_linux
EOF

echo "[*] Network abstractions bypassed! Forcing Ansible playbook to execute via uniquely generated NAT routing file..."

export ANSIBLE_HOST_KEY_CHECKING=False

# Run using our entirely foolproof generated inventory!
ansible-playbook -i localhosts.ini ansible/site.yml
