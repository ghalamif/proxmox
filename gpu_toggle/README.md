# GPU Toggle 

Tiny bash helpers for machines that moonlight between VM passthrough and on-host CUDA work. Has two moods:
- `gpu-mode`: flips a 3090 between `vfio-pci` (VM) and `nvidia` (host).
- `gpu-monitor`: screams (beep + yellow text) if the GPU vanishes.

## Quick start
```bash
# Host mode (use GPU locally)
sudo /root/gpu-mode.sh host

# Passthrough mode (hand GPU to VM)
sudo /root/gpu-mode.sh vfio

# Watchdog with beeps every 5s
sudo /root/gpu-monitor.sh 5
```

## Scripts
- `gpu-mode.sh`: shows who is using the GPU before switching; binds GPU to `nvidia` in host mode and to `vfio-pci` in VM mode. Audio function binds to `snd_hda_intel` in host mode.
- `gpu-monitor.sh`: green OK, yellow WARN, beeps via `pcspkr`/`beep` if `nvidia-smi` fails, falls back to terminal bell.

## Requirements
- Debian/Proxmox host with the 3090 at `0000:01:00.{0,1}` (adjust if different).
- Packages: `beep` (for the real chassis beep), `lsof` (for process listings).
- `pcspkr` kernel module loaded (monitor auto-modprobes it).

## Behavior notes
- `vfio` -> `host`: unbinds vfio, loads `nvidia*`, binds audio to `snd_hda_intel`, enables persistence mode.
- `host` -> `vfio`: turns persistence off, unloads `nvidia*`, binds both functions to `vfio-pci`.
- If a switch fails (device busy), the script prints current GPU users (nvidia-smi, fuser, lsof) so you know what to kill or stop.

## Future distro-ability
- Package as a `.deb` or Homebrew formula; until then, drop the scripts in `/usr/local/bin` and go.
- Add a tiny `install.sh` to fetch updates from a repo, and a systemd timer to auto-update if you like living dangerously.

## Warranty
None. If your speaker beeps at 3 a.m., that means it works.
