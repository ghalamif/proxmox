#!/usr/bin/env bash
set -euo pipefail

# Toggle the RTX 3090 between host (NVIDIA driver) and VM passthrough (vfio-pci).
# Usage:
#   ./gpu-mode.sh host   # bind to NVIDIA driver for local use (Ray, CUDA, etc.)
#   ./gpu-mode.sh vfio   # bind back to vfio-pci for VM passthrough

GPU_ADDR="0000:01:00.0"
GPU_AUDIO_ADDR="0000:01:00.1"

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
  fi
}

unbind_if_bound() {
  local driver="$1"
  local dev="$2"
  local path="/sys/bus/pci/drivers/${driver}/${dev}"
  if [[ -e "${path}" ]]; then
    echo "${dev}" > "/sys/bus/pci/drivers/${driver}/unbind"
  fi
}

bind_driver() {
  local driver="$1"
  local dev="$2"
  local devpath="/sys/bus/pci/devices/${dev}"
  local current_driver=""
  if [[ -L "${devpath}/driver" ]]; then
    current_driver="$(basename "$(readlink -f "${devpath}/driver")")"
  fi

  # If already on the desired driver, nothing to do.
  if [[ "${current_driver}" == "${driver}" ]]; then
    return
  fi

  # If bound to another driver, unbind first to avoid "device busy".
  if [[ -n "${current_driver}" && -e "/sys/bus/pci/drivers/${current_driver}/unbind" ]]; then
    if ! echo "${dev}" > "/sys/bus/pci/drivers/${current_driver}/unbind"; then
      echo "Failed to unbind ${dev} from ${current_driver} (device busy?)." >&2
      show_gpu_users
      exit 1
    fi
  fi

  # Set override so the desired driver is used immediately.
  if ! echo "${driver}" > "${devpath}/driver_override"; then
    echo "Failed to set driver_override=${driver} for ${dev} (device busy?)." >&2
    show_gpu_users
    exit 1
  fi
  # Bind if not already bound.
  if [[ ! -L "/sys/bus/pci/drivers/${driver}/${dev}" ]]; then
    if ! echo "${dev}" > "/sys/bus/pci/drivers/${driver}/bind"; then
      echo "Failed to bind ${dev} to ${driver} (device busy?)." >&2
      show_gpu_users
      exit 1
    fi
  fi
}

clear_override() {
  local dev="$1"
  echo "" > "/sys/bus/pci/devices/${dev}/driver_override"
}

show_gpu_users() {
  echo "== GPU users =="
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser -v /dev/nvidia* /dev/nvidia-uvm* /dev/dri/* 2>/dev/null || true
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof /dev/nvidia* /dev/dri/* 2>/dev/null || true
  fi
}

to_host() {
  printf "Switching GPU to host (NVIDIA driver)...\n"
  # Detach from vfio if present.
  unbind_if_bound "vfio-pci" "${GPU_AUDIO_ADDR}"
  unbind_if_bound "vfio-pci" "${GPU_ADDR}"

  # Load NVIDIA stack.
  modprobe nvidia nvidia_uvm nvidia_drm

  # Bind GPU to NVIDIA; bind audio function to its normal driver (snd_hda_intel).
  bind_driver "nvidia" "${GPU_ADDR}"
  modprobe snd_hda_intel 2>/dev/null || true
  bind_driver "snd_hda_intel" "${GPU_AUDIO_ADDR}"

  # Optional but helpful for stability between jobs.
  nvidia-smi -pm 1 || true

  printf "Done. Verify with: lspci -nnk -d 10de:2204 && nvidia-smi\n"
}

to_vfio() {
  printf "Switching GPU back to vfio-pci (passthrough)...\n"

  # Show who is using the GPU before attempting to unload.
  show_gpu_users

  # Turn off persistence if possible and unload NVIDIA.
  nvidia-smi -pm 0 2>/dev/null || true
  modprobe -r nvidia_drm nvidia_uvm nvidia 2>/dev/null || true

  # Bind GPU and audio to vfio-pci.
  bind_driver "vfio-pci" "${GPU_ADDR}"
  bind_driver "vfio-pci" "${GPU_AUDIO_ADDR}"

  # Clear overrides so boot-time vfio.conf still applies.
  clear_override "${GPU_ADDR}"
  clear_override "${GPU_AUDIO_ADDR}"

  printf "Done. Verify with: lspci -nnk -d 10de:2204\n"
}

main() {
  require_root
  case "${1:-}" in
    host) to_host ;;
    vfio) to_vfio ;;
    *)
      echo "Usage: $0 {host|vfio}" >&2
      exit 1
      ;;
  esac
}

main "$@"
