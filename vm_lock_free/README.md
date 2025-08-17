# Proxmox VM Lock-Free Script

## 📌 Overview
`vmlockfree.bash` is a helper script for **Proxmox VE** that automatically detects and removes **stale VM locks**, clears broken passthrough entries, and restarts VMs safely.  

It was created because sometimes VMs get stuck in a **locked state** (`can't lock file '/var/lock/qemu-server/lock-<id>.conf' - got timeout`) due to:
- Incomplete shutdowns
- Failed PCI passthrough attempts
- Interrupted migrations or snapshots
- Stale PID or lock files

This script helps recover from those states quickly, without needing to manually edit VM configuration files.

---

## 🚀 Features
- Detects and **kills processes holding stale lock files**
- Runs `qm unlock` and **removes leftover lock files**
- Cleans stale `lock:` entries from `/etc/pve/qemu-server/<id>.conf`
- Removes broken **PCI passthrough (`hostpci*`)** lines via `qm set -delete`
- Deletes stale **PID files** if no process exists
- Restarts `pvedaemon` and `pvestatd` (safe for running VMs)
- Starts the VM again with `--skiplock`
- Color-coded logging for better visibility
- Prints a final **summary table** (green = running, red = stopped, yellow = unlocked only)

---

## 🛠️ Usage
Make the script executable:
```bash
chmod +x vmlockfree.bash
```

Run it for one VM:
```bash
sudo ./vmlockfree.bash 102
```

Run it for multiple VMs:
```bash
sudo ./vmlockfree.bash 101 102 103
```

Dry run (just show actions, don’t execute):
```bash
DRY_RUN=1 ./vmlockfree.bash 102
```

Unlock only (don’t auto-start the VM):
```bash
NO_START=1 ./vmlockfree.bash 102
```

---

## ✅ Example Output
```text
=== VM 102 ===
[*]   State: stopped
[WARN] Killing lock holder PID 59041 (file: /run/lock/qemu-server/lock-102.conf)
[*]   Clearing qm lock + lock files
[OK]  Locks cleared
[WARN] Removing 'lock:' from /etc/pve/qemu-server/102.conf
[WARN] Removing PCI passthrough (hostpci*) via qm set
[*]   Restarting pvedaemon & pvestatd
[*]   Starting VM 102 (skiplock)…
[OK]  VM 102 started
[OK]  Final: status: running

===== SUMMARY =====
VM 102: RUNNING
```

---

## 🤔 Why use this script?
- Saves time: no manual editing of config files or digging through logs  
- Safer: uses `qm set` where possible instead of raw `sed` edits  
- Visual: color-coded output helps quickly see what happened  
- Recovery: lets you get back into your VMs when the **Proxmox GUI refuses to start them** due to lock errors  

---

## ⚠️ Disclaimer
This script is designed for **lab and homelab environments**.  
Always double-check your VM configs before using in production clusters.  
Use at your own risk.
