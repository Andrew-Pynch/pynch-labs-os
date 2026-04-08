#!/bin/bash
set -euo pipefail

# Boot the omarchy development VM with QEMU/KVM.
#
# Features:
#   - KVM hardware acceleration
#   - UEFI firmware (OVMF)
#   - 9p filesystem sharing (your fork is available at /mnt/omarchy-dev in the VM)
#   - SSH on host port 2222
#   - Serial console + graphical display
#
# Usage:
#   ./dev/run-vm.sh                    # Boot normally
#   ./dev/run-vm.sh --ssh              # Boot headless, SSH only
#   ./dev/run-vm.sh --cpus 8 --ram 16  # Custom resources
#   ./dev/run-vm.sh --share /path      # Override shared directory

# --- Configuration -----------------------------------------------------------

VM_NAME="${VM_NAME:-omarchy-test}"
VM_DIR="${VM_DIR:-$HOME/.local/share/omarchy-dev/vms}"
DISK_PATH="$VM_DIR/$VM_NAME.qcow2"
CPUS="${CPUS:-4}"
RAM="${RAM:-8}"  # GB
SSH_PORT="${SSH_PORT:-2222}"
HEADLESS=false

# Default share path: the repo root (parent of dev/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_PATH="${SHARE_PATH:-$(dirname "$SCRIPT_DIR")}"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh|--headless) HEADLESS=true; shift ;;
    --cpus)     CPUS="$2"; shift 2 ;;
    --ram)      RAM="$2"; shift 2 ;;
    --share)    SHARE_PATH="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    *)          echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Preflight ---------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $1"; }
error() { echo -e "${RED}==> ERROR:${NC} $1"; exit 1; }

[[ -f "$DISK_PATH" ]] || error "Disk not found: $DISK_PATH\nRun: sudo ./dev/create-vm.sh first"
command -v qemu-system-x86_64 &>/dev/null || error "Missing qemu. Install: sudo pacman -S qemu-full"

# Find OVMF firmware
OVMF=""
for candidate in \
  /usr/share/edk2/x64/OVMF.4m.fd \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/edk2-ovmf/x64/OVMF.4m.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/qemu/OVMF.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF="$candidate"
    break
  fi
done
[[ -n "$OVMF" ]] || error "OVMF firmware not found. Install: sudo pacman -S edk2-ovmf"

# Create a writable copy of the OVMF vars if needed
OVMF_VARS_TEMPLATE=""
for candidate in \
  /usr/share/edk2/x64/OVMF_VARS.4m.fd \
  /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
  /usr/share/OVMF/OVMF_VARS.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF_VARS_TEMPLATE="$candidate"
    break
  fi
done

OVMF_VARS="$VM_DIR/${VM_NAME}_OVMF_VARS.fd"
if [[ -n "$OVMF_VARS_TEMPLATE" && ! -f "$OVMF_VARS" ]]; then
  cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
  info "Created OVMF vars: $OVMF_VARS"
fi

# --- Build QEMU command ------------------------------------------------------

RAM_MB=$(( RAM * 1024 ))

QEMU_ARGS=(
  qemu-system-x86_64
  -name "$VM_NAME"
  -machine q35,accel=kvm
  -cpu host
  -smp "$CPUS"
  -m "${RAM_MB}M"

  # UEFI firmware
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF"
)

# Add writable OVMF vars if available
if [[ -f "$OVMF_VARS" ]]; then
  QEMU_ARGS+=(-drive "if=pflash,format=raw,file=$OVMF_VARS")
fi

QEMU_ARGS+=(
  # Disk
  -drive "file=$DISK_PATH,format=qcow2,if=virtio,cache=writeback"

  # Network with SSH port forward
  -nic "user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT}-:22"

  # 9p filesystem sharing: mount in VM with:
  #   sudo mount -t 9p -o trans=virtio,version=9p2000.L omarchy-share /mnt/omarchy-dev
  -virtfs "local,path=$SHARE_PATH,mount_tag=omarchy-share,security_model=mapped-xattr,id=omarchy-share"

  # Audio (virtio for Pipewire compatibility)
  -device virtio-sound-pci

  # USB
  -device qemu-xhci
  -device usb-kbd
  -device usb-tablet

  # Serial console (accessible via -nographic or terminal)
  -serial mon:stdio
)

# Display mode
if $HEADLESS; then
  QEMU_ARGS+=(-nographic)
else
  QEMU_ARGS+=(
    # Virtio GPU for Wayland/Hyprland compatibility
    -device virtio-vga-gl
    -display gtk,gl=on
  )
fi

# --- Launch ------------------------------------------------------------------

info "Launching VM: $VM_NAME"
echo "  CPUs:    $CPUS"
echo "  RAM:     ${RAM}G"
echo "  Disk:    $DISK_PATH"
echo "  Share:   $SHARE_PATH -> /mnt/omarchy-dev (in VM)"
echo "  SSH:     ssh -p $SSH_PORT $VM_USER@localhost"
echo "  OVMF:    $OVMF"
echo ""

if ! $HEADLESS; then
  info "Graphical display will open. Serial console available here."
  info "Press Ctrl+A, X to kill QEMU from this terminal."
fi

echo ""

exec "${QEMU_ARGS[@]}"
