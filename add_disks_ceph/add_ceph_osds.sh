#!/usr/bin/env bash
# add_ceph_osds.sh - Add new disks as Ceph OSDs on a Proxmox node
# Requires: Proxmox VE node with Ceph installed and configured (pveceph), root privileges.
#
# Usage:
#   ./add_ceph_osds.sh [--yes] [--zap-only] [/dev/sdX|/dev/nvmeXnY|/dev/disk/by-id/...] [...]
#
# Examples:
#   ./add_ceph_osds.sh /dev/sda /dev/sdb
#   ./add_ceph_osds.sh --yes /dev/disk/by-id/ata-WDC_WD20EZAZ-00L9GB0_ABC123
#
# Notes:
# - This script will (optionally) ZAP the given disks (DESTROYS ALL DATA) and then create Ceph OSDs.
# - It uses 'pveceph osd create <device>' which sets up Bluestore OSDs on Proxmox.
# - Prefer using /dev/disk/by-id/* device paths to avoid surprises if kernel renames sdX on reboot.
#
set -euo pipefail

# ------------- Colors -------------
RED="\033[0;31m"; GREEN="\033[0;32m"; YEL="\033[1;33m"; BLU="\033[0;34m"; NC="\033[0m"
say() { printf "%b%s%b\n" "$1" "$2" "$NC"; }
OK(){ say "$GREEN" "[OK]  $*"; }
WARN(){ say "$YEL"  "[WARN] $*"; }
ERR(){ say "$RED"   "[ERR] $*"; }
INFO(){ say "$BLU"  "[*]   $*"; }

# ------------- Root check -------------
if [[ $EUID -ne 0 ]]; then
  ERR "Run as root (sudo)."
  exit 1
fi

# ------------- Dependencies -------------
need_bins=(ceph-volume pveceph lsblk grep awk sed)
for b in "${need_bins[@]}"; do
  command -v "$b" >/dev/null 2>&1 || { ERR "Missing dependency: $b"; exit 1; }
done

# ------------- Args -------------
AUTO_YES=0
ZAP_ONLY=0
DEVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_YES=1; shift ;;
    --zap-only) ZAP_ONLY=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage:
  add_ceph_osds.sh [--yes] [--zap-only] [/dev/sdX|/dev/nvmeXnY|/dev/disk/by-id/...]+

Options:
  --yes, -y     Skip interactive confirmation (DANGEROUS).
  --zap-only    Only zap (wipe) the disks; do not create OSDs.
  --help        Show this help.

Examples:
  add_ceph_osds.sh /dev/sda /dev/sdb
  add_ceph_osds.sh --yes /dev/disk/by-id/ata-WDC_WD20EZAZ-00L9GB0_ABC123
EOF
      exit 0
      ;;
    *)
      DEVICES+=("$1"); shift ;;
  esac
done

if [[ ${#DEVICES[@]} -eq 0 ]]; then
  ERR "No devices provided. Example: $0 /dev/sda /dev/sdb"
  exit 1
fi

# ------------- Show plan -------------
INFO "Target devices:"
for d in "${DEVICES[@]}"; do
  if [[ ! -b "$d" ]]; then
    ERR "Not a block device: $d"
    exit 1
  fi
  lsblk -no NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$d" || true
done

if [[ $AUTO_YES -eq 0 ]]; then
  echo
  WARN "This will ZAP (DESTROY ALL DATA on) the devices above and add them as Ceph OSDs."
  read -rp "Continue? [yes/NO]: " ans
  if [[ "$ans" != "yes" ]]; then
    INFO "Aborted."
    exit 0
  fi
fi

# ------------- Function to check if device seems in use -------------
in_use() {
  local dev="$1"
  # If it has partitions or mountpoints or filesystem, consider in use.
  if lsblk -no MOUNTPOINT "$dev" | grep -q . ; then return 0; fi
  if lsblk -no FSTYPE "$dev" | grep -q . ; then return 0; fi
  if lsblk -no TYPE "$dev" | grep -q "part" ; then return 0; fi
  return 1
}

# ------------- Process each device -------------
for dev in "${DEVICES[@]}"; do
  echo
  INFO "Processing $dev"

  if in_use "$dev"; then
    WARN "$dev appears to have partitions or filesystems/mounts."
    WARN "Proceeding will destroy all data."
    if [[ $AUTO_YES -eq 0 ]]; then
      read -rp "Type 'zap' to wipe $dev or anything else to skip: " conf
      if [[ "$conf" != "zap" ]]; then
        INFO "Skipping $dev"
        continue
      fi
    fi
  fi

  # Zap disk (destroy metadata/partitions)
  INFO "Zapping $dev with ceph-volume (this may take a while)"
  ceph-volume lvm zap "$dev" --destroy || { ERR "Failed to zap $dev"; exit 1; }
  OK "Zapped $dev"

  if [[ $ZAP_ONLY -eq 1 ]]; then
    WARN "--zap-only set, not creating OSD on $dev"
    continue
  fi

  # Create OSD
  INFO "Creating OSD on $dev via pveceph"
  if pveceph osd create "$dev"; then
    OK "OSD created on $dev"
  else
    ERR "Failed to create OSD on $dev"
    exit 1
  fi
done

echo
INFO "Cluster status (summary):"
ceph -s || true

echo
INFO "OSD tree:"
ceph osd tree || true

OK "Done."
