# Pynch Labs OS - Development Documentation

Fork of [omarchy](https://github.com/basecamp/omarchy), an Arch Linux-based distribution.

## Architecture Overview

Omarchy is an **installer**, not an ISO. It runs on vanilla Arch Linux and:
- Installs 148+ packages via pacman/AUR (`install/omarchy-base.packages`)
- Applies 60+ system configurations (`install/config/all.sh`)
- Sets up Hyprland, Waybar, and the full desktop environment
- Manages 19 color themes with template-based config generation

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `bin/` | 210+ `omarchy-*` commands (on PATH) |
| `config/` | Default configs copied to `~/.config/` |
| `default/themed/` | Template files with `{{ variable }}` placeholders for theming |
| `themes/` | Color theme definitions (`colors.toml`) |
| `install/` | Installation framework (preflight, packaging, config, login, post-install) |
| `migrations/` | Timestamped migration scripts for updates |
| `dev/` | VM development/testing tooling (this fork only) |

### Install Guards

The installer (`install/preflight/guard.sh`) requires:
- Vanilla Arch Linux (no derivatives like Manjaro, EndeavourOS, CachyOS)
- x86_64 architecture
- btrfs root filesystem
- Limine bootloader
- Secure Boot disabled
- No existing GNOME or KDE installation
- Running as regular user (not root)

---

## Development Setup

### Prerequisites

Install QEMU/KVM and supporting packages:

```bash
sudo pacman -S qemu-full edk2-ovmf arch-install-scripts gptfdisk dosfstools btrfs-progs
```

Optional (for GUI management and libvirt snapshots):
```bash
sudo pacman -S virt-manager libvirt dnsmasq
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER
# Log out and back in for group changes
```

### Quick Start

```bash
# 1. Build the VM disk image (~5-10 min, one-time)
sudo ./dev/create-vm.sh

# 2. Boot the VM
./dev/run-vm.sh

# 3. Inside the VM, install omarchy:
#    Mount the shared filesystem (your local repo):
sudo mkdir -p /mnt/omarchy-dev
sudo mount -t 9p -o trans=virtio,version=9p2000.L omarchy-share /mnt/omarchy-dev

#    Run the installer:
/mnt/omarchy-dev/dev/vm-install.sh

# 4. Reboot the VM -- you should land in Hyprland
```

### SSH Access

From your host, while the VM is running:
```bash
ssh -p 2222 omarchy@localhost
# Password: omarchy
```

---

## VM Workflow

### Snapshot Management

Snapshots let you save/restore VM state instantly. The `clean-arch` snapshot is created automatically by `create-vm.sh`.

```bash
# List snapshots
./dev/vm-snapshot.sh list

# Save current state
./dev/vm-snapshot.sh save post-install

# Revert to clean Arch (pre-omarchy) -- takes ~2 seconds
./dev/vm-snapshot.sh revert clean-arch

# Revert to post-install state
./dev/vm-snapshot.sh revert post-install
```

### Development Loop

```
 Edit code locally
       |
       v
 Boot VM (./dev/run-vm.sh)
       |  Your local repo is shared into the VM via 9p filesystem
       v
 In VM: run /mnt/omarchy-dev/dev/vm-install.sh
       |
       v
 Test changes in the VM
       |
       +---> Broken? --> ./dev/vm-snapshot.sh revert clean-arch --> fix --> retry
       |
       +---> Working? --> ./dev/vm-snapshot.sh save <milestone> --> commit
```

### VM Configuration

| Setting | Default | Override |
|---------|---------|---------|
| CPUs | 4 | `./dev/run-vm.sh --cpus 8` |
| RAM | 8 GB | `./dev/run-vm.sh --ram 16` |
| SSH port | 2222 | `./dev/run-vm.sh --ssh-port 2223` |
| Headless | off | `./dev/run-vm.sh --ssh` |
| Share path | repo root | `./dev/run-vm.sh --share /other/path` |

### Recreating the VM

To start completely fresh:
```bash
rm -rf ~/.local/share/omarchy-dev/vms/
sudo ./dev/create-vm.sh
```

---

## Customization Guide

### Theming

Themes live in `themes/<name>/colors.toml`. Each defines colors used across the entire desktop:

```toml
accent = "#7aa2f7"
background = "#1a1b26"
foreground = "#c0caf5"
color0 = "#15161e"
# ... color0-color15
```

Template files in `default/themed/*.tpl` use `{{ variable }}` placeholders that get replaced with theme colors when `omarchy-theme-set <name>` runs.

To create a new theme:
1. Copy an existing theme directory: `cp -r themes/tokyo-night themes/my-theme`
2. Edit `themes/my-theme/colors.toml`
3. Test: `omarchy-theme-set my-theme`

### Adding Packages

- Base packages: `install/omarchy-base.packages` (one per line)
- Hardware-specific: `install/omarchy-other.packages`
- Installed via `omarchy-pkg-add` which handles both pacman and AUR

### Adding Commands

Commands go in `bin/` with the `omarchy-` prefix. Follow the naming convention in `AGENTS.md`:
- `cmd-` for utilities
- `pkg-` for package management
- `hw-` for hardware detection
- `refresh-` for config refresh
- `setup-` for interactive wizards
- `theme-` for theme management

### Config Changes

1. Edit files in `config/` (these are the defaults)
2. Run the corresponding `omarchy-refresh-*` command to apply
3. Or for themed configs, edit the template in `default/themed/` and run `omarchy-theme-set`

### Migrations

For changes that need to run on existing installations:
```bash
omarchy-dev-add-migration --no-edit
# Edit the created file in migrations/
```

Migration format (no shebang):
```bash
echo "Description of what this migration does"
# migration commands here
```

---

## File Locations

| What | Host (your repo) | VM (installed) | User config |
|------|------------------|----------------|-------------|
| Omarchy source | `/home/andrew/work/pynch-labs-os/` | `~/.local/share/omarchy/` | -- |
| Hyprland config | `config/hypr/` | -- | `~/.config/hypr/` |
| Waybar config | `config/waybar/` | -- | `~/.config/waybar/` |
| Theme colors | `themes/*/colors.toml` | -- | -- |
| Themed templates | `default/themed/*.tpl` | -- | -- |
| Install log | -- | `/var/log/omarchy-install.log` | -- |
| VM disk | -- | -- | `~/.local/share/omarchy-dev/vms/` |
