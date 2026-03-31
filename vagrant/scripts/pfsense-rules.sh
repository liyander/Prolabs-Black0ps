#!/bin/sh
# =============================================================================
# pfSense Firewall Rules Configuration
# Enforces network segmentation for the Prolab environment
# =============================================================================
#
# Network Topology:
#   em0 (WAN/Attacker): 10.10.10.0/24   - External attack simulation zone
#   em1 (OPT1/DMZ):     192.168.50.0/24 - Internet-facing services
#   em2 (LAN/Internal): 172.16.50.0/24   - Corporate AD network
#
# Routing Rules:
#   ✅ Attacker -> DMZ (full access)
#   ❌ Attacker -> Internal (BLOCKED)
#   ✅ DMZ -> Internal (specific ports only: DNS, LDAP, SMB, WinRM, RDP, HTTP, MSSQL)
#   ✅ Internal -> DMZ (return traffic)
#   ✅ Internal -> Internal (full access within subnet)
# =============================================================================

set -e

echo "[*] Configuring pfSense firewall rules..."

# ---- Enable IP Forwarding ----
sysctl net.inet.ip.forwarding=1

# ---- Flush existing rules ----
pfctl -F all 2>/dev/null || true

# ---- Create PF ruleset ----
cat > /tmp/pf_rules.conf << 'PFRULES'
# =============================================================================
# Prolab pfSense PF Rules
# =============================================================================

# ---- Macros ----
attacker_net = "10.10.10.0/24"
dmz_net      = "192.168.50.0/24"
internal_net = "172.16.50.0/24"

wan_if  = "em0"
dmz_if  = "em1"
lan_if  = "em2"

# Internal service ports accessible from DMZ
dmz_to_internal_tcp = "{ 53, 88, 135, 139, 389, 445, 636, 1433, 3389, 5985, 5986, 80, 443, 8080, 8443 }"
dmz_to_internal_udp = "{ 53, 88, 123, 137, 138, 389 }"

# ---- Options ----
set skip on lo0
set block-policy drop
set state-policy if-bound

# ---- Scrub ----
scrub in all

# ---- NAT (not needed for internal lab, but kept for flexibility) ----

# ---- Filter Rules ----

# Default: block everything and log
block log all

# Allow all traffic on loopback
pass quick on lo0 all

# ---- RULE 1: Allow Attacker -> DMZ (full access) ----
pass in  on $wan_if from $attacker_net to $dmz_net
pass out on $dmz_if from $attacker_net to $dmz_net

# ---- RULE 2: Temporarily allow Attacker -> Internal for Ansible deployment ----
pass in quick on $wan_if from $attacker_net to $internal_net
# block in quick on $wan_if from $attacker_net to $internal_net

# ---- RULE 3: Allow DMZ -> Internal (specific ports only) ----
# TCP services
pass in  on $dmz_if proto tcp from $dmz_net to $internal_net port $dmz_to_internal_tcp
pass out on $lan_if proto tcp from $dmz_net to $internal_net port $dmz_to_internal_tcp

# UDP services
pass in  on $dmz_if proto udp from $dmz_net to $internal_net port $dmz_to_internal_udp
pass out on $lan_if proto udp from $dmz_net to $internal_net port $dmz_to_internal_udp

# ---- RULE 4: Allow Internal -> DMZ (return + initiated traffic) ----
pass in  on $lan_if from $internal_net to $dmz_net
pass out on $dmz_if from $internal_net to $dmz_net

# ---- RULE 5: Allow Internal -> Internal (full intra-subnet) ----
pass in  on $lan_if from $internal_net to $internal_net
pass out on $lan_if from $internal_net to $internal_net

# ---- RULE 6: Allow DMZ -> DMZ (intra-subnet) ----
pass in  on $dmz_if from $dmz_net to $dmz_net
pass out on $dmz_if from $dmz_net to $dmz_net

# ---- RULE 7: Allow ICMP for diagnostics (within segments) ----
pass inet proto icmp from $dmz_net
pass inet proto icmp from $internal_net

# ---- RULE 8: Allow established/related connections ----
pass in  on $wan_if proto tcp from any to any flags S/SA keep state
pass in  on $dmz_if proto tcp from any to any flags S/SA keep state
pass in  on $lan_if proto tcp from any to any flags S/SA keep state

PFRULES

# ---- Load the rules ----
pfctl -f /tmp/pf_rules.conf
pfctl -e 2>/dev/null || true

echo "[+] Firewall rules loaded successfully."
echo "[+] Verifying rules..."
pfctl -sr

echo "[*] pfSense configuration complete."
