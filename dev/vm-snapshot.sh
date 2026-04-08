#!/bin/bash
set -euo pipefail

# Manage qcow2 snapshots for the omarchy development VM.
#
# Usage:
#   ./dev/vm-snapshot.sh list                 # List all snapshots
#   ./dev/vm-snapshot.sh save <name>          # Create a snapshot
#   ./dev/vm-snapshot.sh revert <name>        # Revert to a snapshot
#   ./dev/vm-snapshot.sh delete <name>        # Delete a snapshot
#
# The VM must be shut down before reverting or saving snapshots.

VM_NAME="${VM_NAME:-omarchy-test}"
VM_DIR="${VM_DIR:-$HOME/.local/share/omarchy-dev/vms}"
DISK_PATH="$VM_DIR/$VM_NAME.qcow2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}==> WARNING:${NC} $1"; }
error() { echo -e "${RED}==> ERROR:${NC} $1"; exit 1; }

[[ -f "$DISK_PATH" ]] || error "Disk not found: $DISK_PATH"

ACTION="${1:-}"
NAME="${2:-}"

case "$ACTION" in
  list)
    info "Snapshots for $VM_NAME:"
    echo ""
    qemu-img snapshot -l "$DISK_PATH" || echo "  (no snapshots)"
    ;;

  save)
    [[ -n "$NAME" ]] || error "Usage: $0 save <name>"
    qemu-img snapshot -c "$NAME" "$DISK_PATH"
    info "Snapshot '$NAME' created"
    ;;

  revert)
    [[ -n "$NAME" ]] || error "Usage: $0 revert <name>"
    warn "Reverting to '$NAME' -- all changes since this snapshot will be lost!"
    qemu-img snapshot -a "$NAME" "$DISK_PATH"
    info "Reverted to '$NAME'"
    ;;

  delete)
    [[ -n "$NAME" ]] || error "Usage: $0 delete <name>"
    qemu-img snapshot -d "$NAME" "$DISK_PATH"
    info "Snapshot '$NAME' deleted"
    ;;

  *)
    echo "Usage: $0 {list|save|revert|delete} [name]"
    echo ""
    echo "Commands:"
    echo "  list              List all snapshots"
    echo "  save <name>       Create a new snapshot"
    echo "  revert <name>     Revert to a snapshot (destructive!)"
    echo "  delete <name>     Delete a snapshot"
    exit 1
    ;;
esac
