#!/usr/bin/env bash
# Proxmox VM stale-lock fixer (colorized, safe, multi-VM)
# Usage:
#   ./vmlockfree.bash 102                 # fix single VM
#   ./vmlockfree.bash 101 102 103         # fix multiple VMs
# Env:
#   NO_START=1   # do not start VMs after unlock
#   DRY_RUN=1    # print actions only

set -euo pipefail

# ---------- Colors ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YEL="\033[1;33m"; BLU="\033[0;34m"; NC="\033[0m"
say() { printf "%b%s%b\n" "$1" "$2" "$NC"; }
OK(){ say "$GREEN" "[OK] $*"; }
WARN(){ say "$YEL" "[WARN] $*"; }
ERR(){ say "$RED" "[ERR]  $*"; }
INFO(){ say "$BLU" "[*]   $*"; }

DRY=${DRY_RUN:-0}
RUN(){ if [[ "$DRY" == "1" ]]; then echo "(dry) $*"; else eval "$*"; fi; }

[[ $# -ge 1 ]] || { ERR "Usage: $0 <vmid> [vmid…]"; exit 1; }

declare -A SUMMARY # vmid -> result

for ID in "$@"; do
  echo -e "\n${YEL}=== VM $ID ===${NC}"

  # Show current state quickly
  STATE=$(qm status "$ID" 2>/dev/null || echo "unknown")
  INFO "State: $STATE"
  CONF="/etc/pve/qemu-server/$ID.conf"

  # 1) Kill any process holding the lock file
  for LF in "/run/lock/qemu-server/lock-$ID.conf" "/var/lock/qemu-server/lock-$ID.conf"; do
    if [[ -e "$LF" ]]; then
      PID=$(lsof -t -- "$LF" 2>/dev/null || true)
      if [[ -n "${PID:-}" ]]; then
        WARN "Killing lock holder PID $PID (file: $LF)"
        RUN "kill -9 $PID || true"
      fi
    fi
  done

  # 2) Clear Proxmox lock state & remove lock files
  INFO "Clearing qm lock + lock files"
  RUN "qm unlock $ID >/dev/null 2>&1 || true"
  RUN "rm -f /run/lock/qemu-server/lock-$ID.conf /var/lock/qemu-server/lock-$ID.conf"
  OK "Locks cleared"

  # 3) Remove stale 'lock:' from config
  if [[ -r "$CONF" ]] && grep -q '^lock:' "$CONF"; then
    WARN "Removing 'lock:' from $CONF"
    RUN "sed -i '/^lock:/d' '$CONF'"
  fi

  # 4) Remove passthrough entries safely (hostpciX)
  if qm config "$ID" | grep -q '^hostpci'; then
    WARN "Removing PCI passthrough (hostpci*) via qm set"
    for i in $(seq 0 9); do
      if qm config "$ID" | grep -q "^hostpci$i:"; then
        RUN "qm set $ID -delete hostpci$i >/dev/null 2>&1 || true"
      fi
    done
  fi

  # 5) Remove stale pid file if no process exists
  PIDFILE="/var/run/qemu-server/$ID.pid"
  if [[ -e "$PIDFILE" ]]; then
    P=$(cat "$PIDFILE" || true)
    if [[ -n "$P" ]] && ! ps -p "$P" >/dev/null 2>&1; then
      WARN "Removing stale pidfile $PIDFILE"
      RUN "rm -f '$PIDFILE'"
    fi
  fi

  # 6) Refresh daemons (safe)
  INFO "Restarting pvedaemon & pvestatd"
  RUN "systemctl restart pvedaemon pvestatd"

  # 7) Start VM (unless NO_START)
  if [[ "${NO_START:-0}" == "1" ]]; then
    WARN "NO_START=1 set — not starting VM $ID"
    SUMMARY["$ID"]="UNLOCKED"
    continue
  fi

  INFO "Starting VM $ID (skiplock)…"
  if RUN "qm start $ID --skiplock >/dev/null 2>&1"; then
    OK "VM $ID started"
  else
    ERR "Start failed for VM $ID — showing recent pvedaemon lines:"
    journalctl -u pvedaemon -n 60 --no-pager | grep -E "qm\[[0-9]+\]:|$ID" || true
  fi

  # 8) Final status
  FINAL=$(qm status "$ID" 2>/dev/null || echo "unknown")
  if [[ "$FINAL" == *"running"* ]]; then
    SUMMARY["$ID"]="RUNNING"
    OK "Final: $FINAL"
  else
    SUMMARY["$ID"]="STOPPED"
    WARN "Final: $FINAL"
  fi
done

# ---------- Summary ----------
echo -e "\n${BLU}===== SUMMARY =====${NC}"
for ID in "$@"; do
  case "${SUMMARY[$ID]:-UNKNOWN}" in
    RUNNING) say "$GREEN" "VM $ID: RUNNING" ;;
    UNLOCKED) say "$YEL" "VM $ID: UNLOCKED (not started)" ;;
    STOPPED) say "$RED" "VM $ID: STOPPED" ;;
    *) say "$RED" "VM $ID: UNKNOWN" ;;
  esac
done

