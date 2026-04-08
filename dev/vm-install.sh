#!/bin/bash
set -euo pipefail

# Run inside the VM to install omarchy from the shared filesystem mount.
#
# Usage (inside VM):
#   # First, mount the shared filesystem:
#   sudo mkdir -p /mnt/omarchy-dev
#   sudo mount -t 9p -o trans=virtio,version=9p2000.L omarchy-share /mnt/omarchy-dev
#
#   # Then run this script:
#   /mnt/omarchy-dev/dev/vm-install.sh

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $1"; }
step()  { echo -e "\n${CYAN}--- $1 ---${NC}"; }

SHARE_MOUNT="/mnt/omarchy-dev"
OMARCHY_DEST="$HOME/.local/share/omarchy"

# --- Mount shared filesystem if not already mounted --------------------------

step "Setting up shared filesystem"

if ! mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
  sudo mkdir -p "$SHARE_MOUNT"
  sudo mount -t 9p -o trans=virtio,version=9p2000.L omarchy-share "$SHARE_MOUNT"
  info "Mounted omarchy-share at $SHARE_MOUNT"
else
  info "Already mounted at $SHARE_MOUNT"
fi

# --- Copy omarchy to expected location ---------------------------------------

step "Copying omarchy to $OMARCHY_DEST"

rm -rf "$OMARCHY_DEST"
mkdir -p "$(dirname "$OMARCHY_DEST")"

# Use rsync to copy, excluding dev artifacts and .git
if command -v rsync &>/dev/null; then
  rsync -a --exclude='dev/' --exclude='.git/' "$SHARE_MOUNT/" "$OMARCHY_DEST/"
else
  cp -r "$SHARE_MOUNT" "$OMARCHY_DEST"
fi

info "Copied to $OMARCHY_DEST"

# --- Run the installer -------------------------------------------------------

step "Running omarchy installer"

cd "$OMARCHY_DEST"
source install.sh
