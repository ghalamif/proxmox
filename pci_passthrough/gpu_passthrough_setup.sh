#!/usr/bin/env bash
# gpu_passthrough_setup.sh
# Generalized host-side setup for GPU passthrough on Proxmox VE.
# - Enables IOMMU (Intel or AMD) in boot cmdline (supports systemd-boot and GRUB)
# - Adds required vfio modules
# - Sets IOMMU options (allow_unsafe_interrupts, ignore_msrs)
# - Blacklists host GPU drivers (nouveau/nvidia/radeon/nvidiafb)
# - Binds specified device IDs to vfio-pci
# - Regenerates initramfs and refreshes bootloader
#
# This script does NOT attach the GPU to a specific VM. Do that later via `qm set`.
#
# Usage:
#   sudo ./gpu_passthrough_setup.sh --ids 10de:2204,10de:1aef
#   sudo ./gpu_passthrough_setup.sh --ids 10de:2204,10de:1aef --no-blacklist
#   sudo ./gpu_passthrough_setup.sh --dry-run
#
# After running: REBOOT the node.
set -euo pipefail

# ---------- colors ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YEL="\033[1;33m"; BLU="\033[0;34m"; NC="\033[0m"
say(){ printf "%b%s%b\n" "$1" "$2" "$NC"; }
ok(){ say "$GREEN" "[OK]  $*"; }
warn(){ say "$YEL"  "[WARN] $*"; }
err(){ say "$RED"   "[ERR] $*"; }
info(){ say "$BLU"  "[*]   $*"; }

# ---------- root check ----------
if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo)."
  exit 1
fi

# ---------- args ----------
IDS=""
NO_BLACKLIST=0
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ids) IDS="$2"; shift 2;;
    --no-blacklist) NO_BLACKLIST=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --ids <vendor:device[,vendor:device,...]> [--no-blacklist] [--dry-run]

Examples:
  $0 --ids 10de:2204,10de:1aef
  $0 --ids 1002:73bf,1002:ab28 --no-blacklist

Notes:
  - The provided IDs are bound to vfio-pci via /etc/modprobe.d/vfio.conf
  - Script supports both systemd-boot and GRUB setups used by Proxmox
  - You must reboot after running.
EOF
      exit 0;;
    *) err "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "$IDS" ]]; then
  err "You must provide --ids, e.g. --ids 10de:2204,10de:1aef"
  exit 1
fi

run(){ if [[ $DRY -eq 1 ]]; then echo "(dry) $*"; else eval "$*"; fi; }

backup_file(){ 
  local f="$1"; 
  if [[ -f "$f" ]]; then 
    run "cp -a '$f' '${f}.bak.$(date +%Y%m%d%H%M%S)'" || true
  fi
}

# ---------- detect CPU vendor ----------
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2}')
if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
  IOMMU_KEY="intel_iommu=on iommu=pt"
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
  IOMMU_KEY="amd_iommu=on iommu=pt"
else
  warn "Unknown CPU vendor ($CPU_VENDOR). Defaulting to intel_iommu=on iommu=pt"
  IOMMU_KEY="intel_iommu=on iommu=pt"
fi
info "CPU vendor: $CPU_VENDOR -> using '$IOMMU_KEY'"

# ---------- set kernel cmdline ----------
if [[ -f /etc/kernel/cmdline ]]; then
  # systemd-boot path (Proxmox on ZFS typically)
  info "Detected systemd-boot (/etc/kernel/cmdline)"
  backup_file /etc/kernel/cmdline
  # ensure required options exist exactly once
  CURRENT=$(cat /etc/kernel/cmdline)
  # remove any existing iommu keys to avoid duplicates
  CLEANED=$(echo "$CURRENT" | sed -E 's/(intel_iommu|amd_iommu)=on//g; s/\biommu=pt\b//g; s/  +/ /g')
  # also add vf framebuffer disables to avoid host grabbing GPU
  NEW="$CLEANED $IOMMU_KEY pcie_acs_override=downstream,multifunction video=vesafb:off,efifb:off nofb nomodeset"
  NEW=$(echo "$NEW" | sed 's/^ *//; s/ *$//')
  if [[ $DRY -eq 0 ]]; then echo "$NEW" > /etc/kernel/cmdline; else echo "(dry) update /etc/kernel/cmdline -> $NEW"; fi
  # refresh
  if command -v proxmox-boot-tool >/dev/null 2>&1; then
    run "proxmox-boot-tool refresh"
  else
    warn "proxmox-boot-tool not found; ensure your bootloader is updated"
  fi
else
  # GRUB path
  info "Detected GRUB (/etc/default/grub)"
  backup_file /etc/default/grub
  if [[ ! -f /etc/default/grub ]]; then
    err "/etc/default/grub not found"; exit 1
  fi
  # inject or replace GRUB_CMDLINE_LINUX_DEFAULT
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    run "sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $IOMMU_KEY pcie_acs_override=downstream,multifunction video=vesafb:off,efifb:off nofb nomodeset\"/' /etc/default/grub"
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $IOMMU_KEY pcie_acs_override=downstream,multifunction video=vesafb:off,efifb:off nofb nomodeset\"" | ( [[ $DRY -eq 1 ]] && cat || tee -a /etc/default/grub >/dev/null )
  fi
  run "update-grub"
fi

# ---------- ensure modules ----------
info "Configuring /etc/modules with vfio modules"
backup_file /etc/modules
touch /etc/modules
for m in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
  if ! grep -qx "$m" /etc/modules 2>/dev/null; then
    ( [[ $DRY -eq 1 ]] && echo "(dry) echo $m >> /etc/modules" ) || echo "$m" >> /etc/modules
  fi
done

# ---------- IOMMU opts ----------
info "Writing IOMMU / KVM options"
backup_file /etc/modprobe.d/iommu_unsafe_interrupts.conf
( [[ $DRY -eq 1 ]] && echo "(dry) write /etc/modprobe.d/iommu_unsafe_interrupts.conf" ) || cat >/etc/modprobe.d/iommu_unsafe_interrupts.conf <<EOF
options vfio_iommu_type1 allow_unsafe_interrupts=1
EOF

backup_file /etc/modprobe.d/kvm.conf
( [[ $DRY -eq 1 ]] && echo "(dry) write /etc/modprobe.d/kvm.conf" ) || cat >/etc/modprobe.d/kvm.conf <<'EOF'
options kvm ignore_msrs=1
EOF

# ---------- blacklist host GPU drivers ----------
if [[ $NO_BLACKLIST -eq 1 ]]; then
  warn "--no-blacklist set; skipping driver blacklist"
else
  info "Blacklisting host GPU drivers to avoid host grabbing the GPU"
  backup_file /etc/modprobe.d/blacklist.conf
  ( [[ $DRY -eq 1 ]] && echo "(dry) write /etc/modprobe.d/blacklist.conf" ) || cat >/etc/modprobe.d/blacklist.conf <<'EOF'
blacklist radeon
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
EOF
fi

# ---------- bind device IDs to vfio-pci ----------
info "Binding device IDs to vfio-pci: $IDS"
backup_file /etc/modprobe.d/vfio.conf
( [[ $DRY -eq 1 ]] && echo "(dry) write /etc/modprobe.d/vfio.conf" ) || cat >/etc/modprobe.d/vfio.conf <<EOF
options vfio-pci ids=$IDS disable_vga=1
EOF

# ---------- rebuild initramfs ----------
info "Updating initramfs for all kernels"
run "update-initramfs -u -k all"

ok "Host-side GPU passthrough configuration applied."
warn "Please REBOOT the node to take effect."
