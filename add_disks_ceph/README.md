# add_ceph_osds.sh — Add new disks as Ceph OSDs on Proxmox

## 📌 Overview
This script automates adding raw disks to **Ceph** as **OSDs** on a **Proxmox VE** node. It safely wipes (zaps) the target disks and uses Proxmox’s helper (`pveceph osd create`) to create Bluestore OSDs.

**Why this script?**
- When you plug new disks, you often need to manually zap and create OSDs.
- It’s easy to make mistakes (wrong device, leftover partitions).
- This script adds checks, confirmation prompts, and colored output to make it safer and faster.

> ⚠️ **Destructive**: Zapping **destroys all data** on the target disks. Double-check device paths (prefer `/dev/disk/by-id/*`).

---

## ✅ Prerequisites
- Proxmox VE node with **Ceph installed & configured** (`pveceph`).
- You’re running this **on the node** where the disks are physically attached.
- Root privileges (use `sudo`).

Check new disks:
```bash
lsblk -f
```

---

## 🚀 Usage
Make it executable:
```bash
chmod +x add_ceph_osds.sh
```

Add two SATA disks as OSDs:
```bash
sudo ./add_ceph_osds.sh /dev/sda /dev/sdb
```

Use **persistent paths** (recommended):
```bash
sudo ./add_ceph_osds.sh /dev/disk/by-id/ata-WDC_WD20EZAZ-00L9GB0_ABC123
```

Non-interactive (skip confirmation, **dangerous**):
```bash
sudo ./add_ceph_osds.sh --yes /dev/sda /dev/sdb
```

Zap only (wipe disks but don’t create OSDs):
```bash
sudo ./add_ceph_osds.sh --zap-only /dev/sda
```

---

## 🧠 What the script does
1. Validates each provided device is a block device.
2. Shows `lsblk` info for visibility.
3. Optional prompt (unless `--yes`): confirms you want to **zap** the disk.
4. Runs `ceph-volume lvm zap <dev> --destroy` to wipe partitions/metadata.
5. Runs `pveceph osd create <dev>` to create a **Bluestore OSD**.
6. Prints `ceph -s` and `ceph osd tree` so you can verify the cluster and new OSDs.

---

## 🧪 Example output
```text
[*]   Target devices:
sda    1.8T disk
sdb    1.8T disk

[WARN] This will ZAP (DESTROY ALL DATA ...)
Continue? [yes/NO]: yes

[*]   Processing /dev/sda
[*]   Zapping /dev/sda with ceph-volume ...
[OK]  Zapped /dev/sda
[*]   Creating OSD on /dev/sda via pveceph
[OK]  OSD created on /dev/sda

[*]   Cluster status (summary):
  cluster: HEALTH_OK
[*]   OSD tree:
  osd.1 up in 1.8T
```

---

## 🧯 Troubleshooting
- `Missing dependency`: ensure `ceph-volume` and `pveceph` are installed on the node.
- `device appears in use`: unmount or remove old partitions, or proceed and confirm **zap**.
- `pveceph osd create` fails:
  - check `journalctl -u ceph-osd@*.service -n 100 --no-pager`
  - verify network/bind addresses, Ceph config, and that MONs are reachable.
- After creation, see new OSDs in:
  - Proxmox GUI → **Ceph → OSD**
  - CLI: `ceph osd tree`

---

## ⚠️ Disclaimer
Use at your own risk. Always verify device names and ensure you have backups.
