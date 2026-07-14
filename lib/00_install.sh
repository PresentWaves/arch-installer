#!/bin/bash
# Phase 00 — Fully scripted Arch Linux installation
# Partition, LUKS2, Btrfs + subvolumes, pacstrap, chroot, systemd-boot, COSMIC desktop
# Run from Arch live ISO only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # used downstream via source
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ── Timezone picker (auto-detect + fzf fallback) ──────────────────────────
pick_timezone() {
    echo ""
    info "Detecting timezone via IP geolocation..."
    local detected
    detected=$(curl -s --max-time 5 http://ip-api.com/json/ 2>/dev/null | grep -oP '"timezone":"\K[^"]+' || true)
    if [[ -n "$detected" ]]; then
        ok "Detected: $detected"
        read -r -p "Use this timezone? [Y/n]: " use_detected
        if [[ -z "$use_detected" || "$use_detected" =~ ^[Yy]$ ]]; then
            TIMEZONE="$detected"
            echo "→ $TIMEZONE"
            return
        fi
    else
        warn "Could not detect timezone via IP"
    fi

    echo ""
    info "Select timezone with fuzzy finder (type to filter, Enter to select)..."
    local selected
    selected=$(timedatectl list-timezones 2>/dev/null | fzf --height=40% --header="Select timezone (Esc = UTC fallback)")
    if [[ -n "$selected" ]]; then
        TIMEZONE="$selected"
    else
        warn "No timezone selected — falling back to UTC"
        TIMEZONE="UTC"
    fi
    echo "→ $TIMEZONE"
}

# ── Mode detection ─────────────────────────────────────────────────────────
REINSTALL=false
REINSTALL_ESP=""
REINSTALL_DISK=""
if [[ "${1:-}" == "--reinstall" ]]; then
    REINSTALL=true
    info "Reinstall mode — existing home/data/snapshots will be preserved"
fi

# ── Cleanup trap ──────────────────────────────────────────────────────────
cleanup() {
    echo ""
    info "Cleaning up..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
}
trap cleanup EXIT

# ── Guard: must be Arch live ISO ──────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    error "Must run as root (from the Arch live ISO)."
fi
if [[ ! -f /etc/arch-release ]]; then
    error "Must run from the Arch live ISO, not an installed system."
fi

# ── Guard: must be UEFI ───────────────────────────────────────────────────
if [[ ! -d /sys/firmware/efi ]]; then
    error "System not booted in UEFI mode. Reboot into UEFI."
fi

# ── Load kernel modules ──────────────────────────────────────────────────
modprobe btrfs 2>/dev/null || true

# ── Install fzf for timezone selection ──────────────────────────────────
info "Installing fzf (fuzzy finder) for timezone picker..."
pacman -S --noconfirm fzf
ok "fzf ready"

# ── Interactive prompts (fallback when no config.env) ──────────────────────
if [[ -z "${USERNAME:-}" || "$USERNAME" == "yourname" ]]; then
    read -r -p "Username: " USERNAME
fi
if [[ -z "${NL_HOSTNAME:-}" ]]; then
    read -r -p "Hostname [Nomad]: " NL_HOSTNAME
    NL_HOSTNAME="${NL_HOSTNAME:-Nomad}"
fi
if [[ -z "${TIMEZONE:-}" ]]; then
    pick_timezone
fi
# ── Config validation ─────────────────────────────────────────────────────
if [[ -z "${USERNAME:-}" ]]; then
    error "USERNAME is required"
fi
if [[ -z "${NL_HOSTNAME:-}" ]]; then
    error "NL_HOSTNAME is required"
fi
if [[ -z "${TIMEZONE:-}" ]]; then
    error "TIMEZONE is required"
fi
info "Config validated (USERNAME=$USERNAME, HOSTNAME=$NL_HOSTNAME, TZ=$TIMEZONE)"

# ── Fresh install or reinstall ─────────────────────────────────────────────
if $REINSTALL; then
    # ── Reinstall: detect existing LUKS ────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  AVAILABLE LUKS PARTITIONS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    lsblk -o NAME,SIZE,TYPE,FSTYPE | grep -E 'crypto_LUKS' || echo "  (no LUKS partitions found)"
    echo ""

    read -r -p "  Enter existing LUKS partition (e.g. \"/dev/nvme0n1p2\"): " LUKS_PART
    LUKS_PART="${LUKS_PART%/}"
    if [[ ! -b "$LUKS_PART" ]]; then
        error "Not a valid block device: $LUKS_PART"
    fi

    # Derive disk and ESP from LUKS partition
    if [[ "$LUKS_PART" =~ /dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
        REINSTALL_DISK="${LUKS_PART%p*}"
        PART_SUFFIX="p"
    elif [[ "$LUKS_PART" =~ /dev/sd[a-z]+[0-9]+$ ]]; then
        REINSTALL_DISK="${LUKS_PART%[0-9]}"
        PART_SUFFIX=""
    else
        error "Cannot determine disk from: $LUKS_PART"
    fi
    REINSTALL_ESP="${REINSTALL_DISK}${PART_SUFFIX}1"

    if [[ ! -b "$REINSTALL_ESP" ]]; then
        error "ESP not found at $REINSTALL_ESP — cannot reinstall"
    fi

    LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART" | tr -d '[:space:]')

    # Confirm reinstall
    echo ""
    echo "  ──────────────────────────────────────────────────────────────────────"
    echo "  Will REPLACE OS on: $REINSTALL_DISK"
    echo "  Preserved: /home, /data, /.snapshots"
    echo "  Wiped:     root, /var, /var/log, /var/cache, /tmp"
    echo "  LUKS/TPM:  untouched (passphrase + TPM keyslot survive)"
    echo "  ──────────────────────────────────────────────────────────────────────"
    echo ""
    read -r -p "  Type \"YES\" (uppercase) to confirm reinstall: " confirm_yes
    if [[ "$confirm_yes" != "YES" ]]; then
        error "Aborted by user"
    fi

    info "Opening existing LUKS2 on $LUKS_PART (enter your passphrase)..."
    cryptsetup open "$LUKS_PART" cryptroot
    ok "LUKS container opened"

    # Delete and recreate OS subvolumes only
    info "Recreating OS subvolumes..."
    mount /dev/mapper/cryptroot /mnt
    for s in @ @var @log @cache @tmp; do
        if btrfs subvolume show "/mnt/$s" &>/dev/null; then
            btrfs subvolume delete --recursive "/mnt/$s" && info "  Deleted old $s"
        fi
    done
    for s in @ @var @log @cache @tmp; do
        btrfs subvolume create "/mnt/$s"
    done
    # Verify home/data/snapshots still exist
    for s in @home @data @snapshots; do
        if ! btrfs subvolume show "/mnt/$s" &>/dev/null; then
            error "Required subvolume $s not found — cannot reinstall"
        fi
    done
    umount /mnt
    ok "Subvolumes ready — @home, @data, @snapshots preserved"

else
    # ── Fresh install ─────────────────────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  AVAILABLE DISKS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    lsblk -o NAME,MODEL,SERIAL,SIZE,TYPE | grep -E 'disk$'
    echo ""

    read -r -p "  Enter target disk (e.g. \"/dev/nvme0n1\" or \"/dev/sda\"): " TARGET_DISK
    TARGET_DISK="${TARGET_DISK%/}"
    if [[ ! -b "$TARGET_DISK" ]]; then
        error "Not a valid block device: $TARGET_DISK"
    fi

    # Show disk identity
    echo ""
    echo "  Disk identity:"
    udevadm info --query=property "$TARGET_DISK" 2>/dev/null \
        | grep -E '^(ID_MODEL|ID_SERIAL_SHORT|ID_SERIAL)=' \
        || echo "  (udevadm info unavailable; continuing with path only)"
    echo ""

    DISK_SERIAL=$(udevadm info --query=property "$TARGET_DISK" 2>/dev/null \
        | grep -oP 'ID_SERIAL_SHORT=\K.*' || true)
    if [[ -z "$DISK_SERIAL" ]]; then
        DISK_SERIAL=$(udevadm info --query=property "$TARGET_DISK" 2>/dev/null \
            | grep -oP 'ID_SERIAL=\K.*' || true)
    fi
    if [[ -z "$DISK_SERIAL" ]]; then
        DISK_SERIAL="UNKNOWN"
    fi

    DISK_SIZE=$(lsblk -n -o SIZE "$TARGET_DISK")

    echo "  ──────────────────────────────────────────────────────────────────────"
    echo "  DANGER: This will DESTROY ALL DATA on:"
    echo "    Device: $TARGET_DISK"
    echo "    Serial: $DISK_SERIAL"
    echo "    Size:   $DISK_SIZE"
    echo "  ──────────────────────────────────────────────────────────────────────"
    echo ""

    read -r -p "  Type the SERIAL above (case-sensitive) to confirm: " confirm_serial
    if [[ "$confirm_serial" != "$DISK_SERIAL" ]]; then
        error "Serial mismatch — aborting"
    fi

    read -r -p "  Type \"YES\" (uppercase) to confirm wipe: " confirm_yes
    if [[ "$confirm_yes" != "YES" ]]; then
        error "Aborted by user"
    fi

    # Determine partition suffix (NVMe uses p1, SATA uses 1)
    if [[ "$TARGET_DISK" =~ /dev/nvme[0-9]+n[0-9]+$ ]]; then
        PART_SUFFIX="p"
    else
        PART_SUFFIX=""
    fi
    ESP="${TARGET_DISK}${PART_SUFFIX}1"
    LUKS_PART="${TARGET_DISK}${PART_SUFFIX}2"

    info "Target: $TARGET_DISK (${DISK_SIZE}) — proceeding"
    info "  ESP:     $ESP"
    info "  LUKS:    $LUKS_PART"

    # ── Partition ─────────────────────────────────────────────────────
    info "Partitioning $TARGET_DISK..."
    sgdisk --zap-all "$TARGET_DISK"
    sgdisk --new=1:0:+1024M --typecode=1:ef00 "$TARGET_DISK"
    sgdisk --new=2:0:0     --typecode=2:8309 "$TARGET_DISK"
    ok "Partitions created"

    # ── LUKS ──────────────────────────────────────────────────────────
    info "Setting up LUKS2 on $LUKS_PART (interactive password)..."
    cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --iter-time 3000 "$LUKS_PART"
    cryptsetup open "$LUKS_PART" cryptroot
    ok "LUKS container opened"

    # ── Filesystems ───────────────────────────────────────────────────
    info "Creating filesystems..."
    mkfs.fat -F32 "$ESP"
    mkfs.btrfs /dev/mapper/cryptroot
    ok "Filesystems created"

    # ── Btrfs subvolumes ──────────────────────────────────────────────
    info "Creating Btrfs subvolumes..."
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@cache
    btrfs subvolume create /mnt/@tmp
    btrfs subvolume create /mnt/@data
    umount /mnt
    ok "Subvolumes created"

    # Capture LUKS UUID for fresh install
    LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART" | tr -d '[:space:]')
fi

# Set ESP from fresh install or reinstall
if $REINSTALL; then
    ESP="$REINSTALL_ESP"
fi

# ── Mount ─────────────────────────────────────────────────────────────────
info "Mounting subvolumes..."
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var,tmp,boot}
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o subvol=@var /dev/mapper/cryptroot /mnt/var
mount -o subvol=@tmp /dev/mapper/cryptroot /mnt/tmp
mkdir -p /mnt/data
mount -o subvol=@data /dev/mapper/cryptroot /mnt/data
mount "$ESP" /mnt/boot
mkdir -p /mnt/var/{cache,log}
mount -o subvol=@cache /dev/mapper/cryptroot /mnt/var/cache
mount -o subvol=@log /dev/mapper/cryptroot /mnt/var/log
ok "Subvolumes mounted"

# ── CPU detection for microcode ──────────────────────────────────────────
if grep -q "GenuineIntel" /proc/cpuinfo; then
    CPU_UCODE="intel-ucode"
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    CPU_UCODE="amd-ucode"
else
    error "Unknown CPU vendor — cannot determine microcode package"
fi
info "Detected CPU: $CPU_UCODE"

# ── Enable ParallelDownloads for faster pacstrap ──────────────────────────
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf

# ── Package groups for pacstrap ───────────────────────────────────────────
SYSTEM_PKGS=(base base-devel linux linux-firmware "$CPU_UCODE" btrfs-progs)
CLI_PKGS=(sudo git github-cli gnupg networkmanager micro opencode trash-cli wl-clipboard)
GPU_PKGS=(mesa vulkan-radeon libva-mesa-driver)
ADMIN_PKGS=(snapper snap-pac inotify-tools zram-generator tpm2-tss)
COSMIC_PKGS=(cosmic-greeter cosmic-comp cosmic-session cosmic-panel cosmic-bg cosmic-settings cosmic-notifications cosmic-osd cosmic-wallpapers cosmic-store cosmic-text-editor)
FLATPAK_PKGS=(flatpak)
WAYLAND_PKGS=(qt5-wayland qt6-wayland xdg-desktop-portal-cosmic)
MEDIA_PKGS=(pipewire-pulse wireplumber noto-fonts noto-fonts-extra noto-fonts-cjk noto-fonts-emoji)
DESKTOP_PKGS=(polkit-gnome network-manager-applet kitty vivaldi vivaldi-ffmpeg-codecs)
CONTAINER_PKGS=(podman podman-docker slirp4netns)
SECURITY_PKGS=(bitwarden bitwarden-cli)
TOOL_PKGS=(age jq rust restic distrobox lite-xl mise uv pcsclite ccid yubikey-manager)

# ── Pacstrap ──────────────────────────────────────────────────────────────
info "Installing base system (pacstrap)..."
pacstrap /mnt \
    "${SYSTEM_PKGS[@]}" \
    "${CLI_PKGS[@]}" \
    "${GPU_PKGS[@]}" \
    "${ADMIN_PKGS[@]}" \
    "${COSMIC_PKGS[@]}" \
    "${FLATPAK_PKGS[@]}" \
    "${WAYLAND_PKGS[@]}" \
    "${MEDIA_PKGS[@]}" \
    "${DESKTOP_PKGS[@]}" \
    "${CONTAINER_PKGS[@]}" \
    "${SECURITY_PKGS[@]}" \
    "${TOOL_PKGS[@]}"
ok "Base system installed"

if [[ ! -x /mnt/usr/lib/systemd/systemd ]]; then
    error "Base system missing systemd. Check pacstrap output."
fi
ok "Base system verified"

# ── Fstab ─────────────────────────────────────────────────────────────────
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/subvolid=[^,]*,\?//g' /mnt/etc/fstab
ok "fstab generated"

# ── Chroot setup script ──────────────────────────────────────────────────
cat > /mnt/chroot-setup.sh << 'CHROOT_SCRIPT'
#!/bin/bash
set -euo pipefail

USERNAME="${1}"
NL_HOSTNAME="${2}"
TIMEZONE="${3}"
LUKS_UUID="${4}"

# Enable parallel downloads in the installed system
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf

# Detect CPU microcode and kernel params for boot entry
if grep -q "GenuineIntel" /proc/cpuinfo; then
    UCODE_IMG="/intel-ucode.img"
    KERNEL_PARAMS=""
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    UCODE_IMG="/amd-ucode.img"
    KERNEL_PARAMS="amd_pstate=active"
else
    echo "Warning: Unknown CPU — assuming AMD for microcode"
    UCODE_IMG="/amd-ucode.img"
    KERNEL_PARAMS="amd_pstate=active"
fi

# Timezone
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "${NL_HOSTNAME}" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${NL_HOSTNAME}.localdomain ${NL_HOSTNAME}
EOF

# mkinitcpio — systemd + sd-encrypt hooks (TPM2-capable, replaces encrypt)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# crypttab.initramfs — TPM2 auto-unlock via systemd-cryptsetup
cat > /etc/crypttab.initramfs << CRYPTTAB_EOF
# <name>      <encrypted device>  <keyfile>  <options>
cryptroot  UUID=${LUKS_UUID}  none  tpm2-device=auto,tpm2-measure-pcr=yes
CRYPTTAB_EOF

mkinitcpio -P

# systemd-boot
bootctl install
mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf << EOF
default  arch.conf
timeout  4
console-mode max
editor   no
EOF

cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  ${UCODE_IMG}
initrd  /initramfs-linux.img
options root=/dev/mapper/cryptroot rw rootflags=subvol=@ ${KERNEL_PARAMS}
EOF

# zram-generator
cat > /etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

# Snapper
snapper -c root create-config / 2>/dev/null || true
snapper -c root create -d "fresh-install" 2>/dev/null || true

# Enable services
systemctl enable NetworkManager systemd-timesyncd cosmic-greeter

# Root password
echo ""
echo "  ────────────────────────────────────────────"
echo "  Set ROOT password"
echo "  ────────────────────────────────────────────"
while true; do
    read -r -s -p "  Root password: " pw1
    echo ""
    read -r -s -p "  Confirm root password: " pw2
    echo ""
    if [[ -n "$pw1" && "$pw1" == "$pw2" ]]; then
        echo "root:${pw1}" | chpasswd
        break
    fi
    echo "  Passwords do not match or are empty. Try again."
done
unset pw1 pw2
echo "[+] Root password set"

# Create user
useradd -m -G wheel,video "${USERNAME}"
while true; do
    read -r -s -p "  Password for ${USERNAME}: " pw1
    echo ""
    read -r -s -p "  Confirm password: " pw2
    echo ""
    if [[ -n "$pw1" && "$pw1" == "$pw2" ]]; then
        echo "${USERNAME}:${pw1}" | chpasswd
        break
    fi
    echo "  Passwords do not match or are empty. Try again."
done
unset pw1 pw2
echo "[+] User password set"

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Editor: micro, remove nano from base group
pacman -Rns --noconfirm nano 2>/dev/null || true
cat > /etc/profile.d/editor.sh << 'EOF'
export EDITOR=micro
export VISUAL=micro
EOF

USER_HOME="/home/${USERNAME}"

# COSMIC — pre-enable auto-tiling
mkdir -p "${USER_HOME}/.config/cosmic/com.system76.CosmicComp/v1"
echo -n 'true' > "${USER_HOME}/.config/cosmic/com.system76.CosmicComp/v1/autotile"
echo -n 'Global' > "${USER_HOME}/.config/cosmic/com.system76.CosmicComp/v1/autotile_behavior"

# Regular XDG target dirs (not dotfiles — Chezmoi owns those)
mkdir -p "${USER_HOME}/Desktop" "${USER_HOME}/Downloads"

# Protect Chezmoi-owned user-dirs.dirs from being reset at session start
mkdir -p /etc/xdg/autostart
ln -sf /dev/null /etc/xdg/autostart/xdg-user-dirs-update.desktop

# Future-proof ownership: chown the whole home + persistent volume.
# chown -R follows symlinks, so this also fixes the real targets behind
# any symlink and stays correct regardless of how folders move later.
chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}"
chown -R "${USERNAME}:${USERNAME}" /data

# Flatpak — add Flathub system-wide (Vivaldi moved to native pacstrap)
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo

# SSH — pre-harden root login (applies when openssh is installed later)
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-disable-root-login.conf << EOF
PermitRootLogin no
EOF

# Clean up self
rm -f /chroot-setup.sh
CHROOT_SCRIPT

chmod +x /mnt/chroot-setup.sh
arch-chroot /mnt /chroot-setup.sh "$USERNAME" "$NL_HOSTNAME" "$TIMEZONE" "$LUKS_UUID"

# ── Clean trap (no-op on success) ─────────────────────────────────────────
trap - EXIT
sync
umount -R /mnt 2>/dev/null || { sleep 2; umount -R /mnt 2>/dev/null || true; }
cryptsetup close cryptroot 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 00 complete!"
echo ""

if $REINSTALL; then
    echo "  ─── Reinstall ─────────────────────────────────────────────────"
    echo "  Preserved: /home, /data, /.snapshots"
    echo "  Fresh OS installed on root subvolume."
    echo ""
fi

echo "  Post-install:"
echo "  1. reboot"
echo "  2. Login at COSMIC desktop"
echo "  3. Drop a shell → bash setup.sh"
echo "     (runs phases 01-08: system, YubiKey, GPG, dotfiles, snapper, restic, TPM, layout...)"
echo ""
echo "  ─── TPM2 Auto-Unlock ───────────────────────────────────"
  echo "  After first boot, enroll TPM2 for password-less unlock:"
echo ""
echo "    sudo bash setup.sh 09"
echo ""
echo "  (or directly: sudo bash lib/09_tpm_enroll.sh)"
echo ""
echo "  IMPORTANT: PCR 7 only measures Secure Boot state. If Secure Boot"
echo "  is disabled, anyone with physical access can tamper with the ESP"
echo "  and the TPM will still unlock. Enable Secure Boot with sbctl, or"
echo "  set TPM_PCRS=0,7 in config.env for stronger binding."
echo ""
echo "  Your LUKS passphrase still works as a fallback."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
