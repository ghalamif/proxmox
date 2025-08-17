# GPU Passthrough Setup (Host-Side) for Proxmox VE

This includes a generalized script to configure **Proxmox VE** host for **GPU passthrough**.  
It performs the host changes only (IOMMU, modules, blacklist, VFIO binding). **It does not modify any VM.**

> After running the script you must **reboot**, then attach the GPU to a VM with `qm set`.

---

## ✅ What the script does

- Detects your CPU vendor (Intel/AMD) and enables **IOMMU** (`intel_iommu=on` or `amd_iommu=on`) + `iommu=pt`  
- Adds recommended kernel parameters: `pcie_acs_override=downstream,multifunction video=vesafb:off efifb:off nofb nomodeset`
- Ensures VFIO modules are loaded at boot: `vfio`, `vfio_iommu_type1`, `vfio_pci`, `vfio_virqfd`
- Sets IOMMU/KVM options: `allow_unsafe_interrupts=1`, `ignore_msrs=1`
- **Blacklists** host GPU drivers (`nvidia`, `nvidiafb`, `nouveau`, `radeon`) so the host doesn’t grab the GPU (can disable with `--no-blacklist`)
- Binds your **device IDs** (e.g., `10de:2204,10de:1aef`) to **vfio-pci`
- Supports both **systemd-boot** (`/etc/kernel/cmdline` + `proxmox-boot-tool refresh`) and **GRUB** (`/etc/default/grub` + `update-grub`)
- Backs up modified files with a timestamp suffix
- Colorized output + `--dry-run` mode

---

## 🛠️ Requirements

- Proxmox VE 7/8
- Run on the **node that hosts the GPU**
- Root privileges

Find your GPU device IDs:
```bash
lspci -nn | grep -i nvidia
# Example (RTX 3090):
# 01:00.0 VGA ... [10de:2204]
# 01:00.1 Audio ... [10de:1aef]
```

Use the IDs inside the brackets: `10de:2204,10de:1aef`.

---

## 🚀 Usage

Make executable:
```bash
chmod +x gpu_passthrough_setup.sh
```

Run with your device IDs:
```bash
sudo ./gpu_passthrough_setup.sh --ids 10de:2204,10de:1aef
```

Optional flags:
- `--no-blacklist` — do not blacklist GPU drivers on the host
- `--dry-run` — print actions without changing the system

When finished, **reboot** the node.

---

## 🎯 Attach the GPU to a VM (manual, after reboot)

> This script doesn’t touch VMs. After reboot, for example VM 102:

```bash
qm set 102 -machine q35
qm set 102 -bios ovmf
qm set 102 -vga none
qm set 102 -hostpci0 01:00.0,pcie=1,x-vga=1
qm set 102 -hostpci1 01:00.1,pcie=1
```

Then install GPU drivers inside the guest and verify with `nvidia-smi`.

---

## 🔧 Troubleshooting

- **Host still loads NVIDIA driver**: ensure blacklist exists and that `lspci -nnk` shows `Kernel driver in use: vfio-pci`.
- **VM boot issues / Code 43**: use `OVMF` + `q35`, optional CPU flags to hide hypervisor; keep Windows updated.
- **systemd-boot vs GRUB**: handled automatically by the script.
- **Multiple GPUs**: include all function IDs in `--ids` (e.g., GPU + audio function).

---

## 🧯 Reverting

- Restore `*.bak.*` backups created by the script, or remove the files in `/etc/modprobe.d/` it created.
- Remove IOMMU flags from `/etc/kernel/cmdline` or `/etc/default/grub`, refresh the bootloader, and `update-initramfs -u -k all`.
- Reboot.
