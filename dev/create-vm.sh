#!/bin/bash
set -euo pipefail

# Automated Arch Linux VM provisioner for omarchy development.
# Builds a bootable qcow2 disk image from the host using pacstrap,
# configured with btrfs + Limine to satisfy all omarchy install guards.
#
# Usage: sudo ./dev/create-vm.sh [--disk-size 60G] [--vm-name omarchy-test]
#
# Must be run as root (needs nbd, mount, pacstrap).
# The resulting image is owned by the calling user.

# --- Configuration -----------------------------------------------------------

VM_NAME="${VM_NAME:-omarchy-test}"
DISK_SIZE="${DISK_SIZE:-60G}"
VM_DIR="${VM_DIR:-$(eval echo ~${SUDO_USER:-$USER})/.local/share/omarchy-dev/vms}"
DISK_PATH="$VM_DIR/$VM_NAME.qcow2"
MOUNT_POINT="/tmp/omarchy-vm-$$"
NBD_DEVICE="/dev/nbd0"
VM_USER="omarchy"
VM_PASSWORD="omarchy"
VM_HOSTNAME="omarchy-vm"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --disk-size) DISK_SIZE="$2"; shift 2 ;;
    --vm-name)   VM_NAME="$2"; shift 2 ;;
    *)           echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Helpers -----------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}==> WARNING:${NC} $1"; }
error() { echo -e "${RED}==> ERROR:${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}--- $1 ---${NC}"; }

# --- Preflight ---------------------------------------------------------------

if (( EUID != 0 )); then
  error "Must be run as root (needs nbd, mount, pacstrap).\nUsage: sudo $0"
fi

check_cmd() { command -v "$1" &>/dev/null || error "Missing: $1. Install: $2"; }

check_cmd qemu-img    "sudo pacman -S qemu-full"
check_cmd qemu-nbd    "sudo pacman -S qemu-full"
check_cmd pacstrap    "sudo pacman -S arch-install-scripts"
check_cmd arch-chroot "sudo pacman -S arch-install-scripts"
check_cmd sgdisk      "sudo pacman -S gptfdisk"
check_cmd mkfs.fat    "sudo pacman -S dosfstools"
check_cmd mkfs.btrfs  "sudo pacman -S btrfs-progs"

# --- Cleanup handler ---------------------------------------------------------

cleanup() {
  info "Cleaning up..."
  # Unmount in reverse order, ignore errors
  umount -R "$MOUNT_POINT" 2>/dev/null || true
  qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
  rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

# --- Create disk image -------------------------------------------------------

step "Creating disk image"

mkdir -p "$VM_DIR"

if [[ -f "$DISK_PATH" ]]; then
  warn "Disk already exists: $DISK_PATH"
  read -p "Overwrite? [y/N] " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 0
  rm -f "$DISK_PATH"
fi

qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
info "Created $DISK_PATH ($DISK_SIZE)"

# --- Connect via NBD ---------------------------------------------------------

step "Connecting disk via NBD"

modprobe nbd max_part=8
qemu-nbd --connect="$NBD_DEVICE" "$DISK_PATH"
sleep 1  # Wait for device to appear

info "Connected to $NBD_DEVICE"

# --- Partition ---------------------------------------------------------------

step "Partitioning (GPT: 512M EFI + btrfs root)"

sgdisk --zap-all "$NBD_DEVICE"
sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFI" "$NBD_DEVICE"
sgdisk --new=2:0:0      --typecode=2:8300 --change-name=2:"root" "$NBD_DEVICE"

partprobe "$NBD_DEVICE"
sleep 1

info "Partition table:"
sgdisk --print "$NBD_DEVICE"

# --- Format ------------------------------------------------------------------

step "Formatting filesystems"

mkfs.fat -F 32 -n EFI "${NBD_DEVICE}p1"
mkfs.btrfs -f -L omarchy "${NBD_DEVICE}p2"

info "EFI: FAT32, Root: btrfs"

# --- Btrfs subvolumes -------------------------------------------------------

step "Creating btrfs subvolumes"

mkdir -p "$MOUNT_POINT"
mount "${NBD_DEVICE}p2" "$MOUNT_POINT"

btrfs subvolume create "$MOUNT_POINT/@"
btrfs subvolume create "$MOUNT_POINT/@home"

umount "$MOUNT_POINT"

# Remount with subvolumes
mount -o subvol=@,compress=zstd "${NBD_DEVICE}p2" "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT/home"
mount -o subvol=@home,compress=zstd "${NBD_DEVICE}p2" "$MOUNT_POINT/home"
mkdir -p "$MOUNT_POINT/boot"
mount "${NBD_DEVICE}p1" "$MOUNT_POINT/boot"

info "Subvolumes @ and @home mounted"

# --- Pacstrap ----------------------------------------------------------------

step "Installing base system (pacstrap)"

pacstrap -K "$MOUNT_POINT" \
  base linux linux-firmware \
  btrfs-progs \
  limine \
  networkmanager \
  sudo \
  git \
  openssh \
  vim \
  bash \
  gum \
  base-devel

info "Base system installed"

# --- Fstab -------------------------------------------------------------------

step "Generating fstab"

genfstab -U "$MOUNT_POINT" >> "$MOUNT_POINT/etc/fstab"

# Fix fstab: replace nbd device references with proper labels/UUIDs
# The VM will use /dev/vda instead of /dev/nbd0
sed -i "s|${NBD_DEVICE}p1|/dev/vda1|g" "$MOUNT_POINT/etc/fstab"
sed -i "s|${NBD_DEVICE}p2|/dev/vda2|g" "$MOUNT_POINT/etc/fstab"

info "Generated /etc/fstab"
cat "$MOUNT_POINT/etc/fstab"

# --- Chroot configuration ----------------------------------------------------

step "Configuring system in chroot"

arch-chroot "$MOUNT_POINT" /bin/bash <<CHROOT_EOF
set -euo pipefail

# Timezone & locale
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$VM_HOSTNAME" > /etc/hostname

# Hosts
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $VM_HOSTNAME
EOF

# Create user with sudo
useradd -m -G wheel -s /bin/bash "$VM_USER"
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD" | chpasswd

# Sudo for wheel group (passwordless for dev convenience)
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

# Enable services
systemctl enable NetworkManager
systemctl enable sshd

# Initramfs
mkinitcpio -P

# --- Limine bootloader setup ---
# Install Limine EFI binary
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

# Get root partition UUID (will be replaced post-chroot)
ROOT_UUID=\$(blkid -s UUID -o value "${NBD_DEVICE}p2" 2>/dev/null || echo "PLACEHOLDER")

# Create Limine config
cat > /boot/limine.conf <<LIMINE_EOF
timeout: 3
default_entry: 1

/Arch Linux
  protocol: linux
  path: boot():/vmlinuz-linux
  cmdline: root=UUID=\$ROOT_UUID rootflags=subvol=@ rw rootfstype=btrfs console=tty0 console=ttyS0,115200
  module_path: boot():/initramfs-linux.img
LIMINE_EOF

echo "Limine configured at /boot/limine.conf"
cat /boot/limine.conf

# Create arch-release marker (guard.sh checks for this)
touch /etc/arch-release

CHROOT_EOF

# Fix the root UUID in limine.conf (blkid from host is more reliable)
ROOT_UUID=$(blkid -s UUID -o value "${NBD_DEVICE}p2")
sed -i "s|root=UUID=PLACEHOLDER|root=UUID=$ROOT_UUID|g" "$MOUNT_POINT/boot/limine.conf"
info "Root UUID: $ROOT_UUID"

# --- Finalize ----------------------------------------------------------------

step "Finalizing"

# Sync and unmount
sync
umount -R "$MOUNT_POINT"
qemu-nbd --disconnect "$NBD_DEVICE"
rmdir "$MOUNT_POINT" 2>/dev/null || true

# Disable cleanup trap since we manually cleaned up
trap - EXIT

# Create initial snapshot
step "Creating 'clean-arch' snapshot"
qemu-img snapshot -c clean-arch "$DISK_PATH"
info "Snapshot 'clean-arch' created"

# Fix ownership
REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP=$(id -gn "$REAL_USER")
chown -R "$REAL_USER:$REAL_GROUP" "$VM_DIR"

# --- Done! -------------------------------------------------------------------

echo ""
info "VM disk created successfully!"
echo ""
echo "  Disk:     $DISK_PATH"
echo "  Size:     $DISK_SIZE"
echo "  User:     $VM_USER"
echo "  Password: $VM_PASSWORD"
echo "  Snapshot: clean-arch"
echo ""
echo "  Next: ./dev/run-vm.sh"
echo ""
