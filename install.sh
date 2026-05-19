#!/usr/bin/env bash
# ============================================================
#  NVIDIA Driver Setup — Multi-Distro
#  Supports: Arch, Fedora, Ubuntu/Debian/PikaOS, openSUSE
#  Usage: curl -fsSL https://get.tlprox.pro.vn/install.sh | sudo bash
# ============================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()   { echo -e "${RED}[ERR]${RESET}   $*"; exit 1; }
step()  { echo -e "\n${BOLD}${GREEN}==>${RESET}${BOLD} $*${RESET}"; }

# ════════════════════════════════════════════════════════════
# PRE-CHECKS
# ════════════════════════════════════════════════════════════
[[ $EUID -ne 0 ]] && err "Chạy với sudo: sudo bash install.sh"

REAL_USER="${SUDO_USER:-}"
[[ -z "$REAL_USER" ]] && err "Chạy bằng: sudo bash install.sh (không dùng sudo su)"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
info "User: $REAL_USER | Home: $REAL_HOME"

if ! lspci | grep -qi nvidia; then
    err "Không phát hiện NVIDIA card!"
fi
GPU_NAME=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
CURRENT_KERNEL=$(uname -r)
info "GPU: $GPU_NAME"
info "Kernel: $CURRENT_KERNEL"

# ── Detect distro ────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    DISTRO="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
else
    DISTRO="unknown"
    DISTRO_LIKE=""
fi

# ── Detect bootloader ────────────────────────────────────────
detect_bootloader() {
    if [[ -d /boot/loader/entries ]] && ls /boot/loader/entries/*.conf &>/dev/null 2>&1; then
        echo "systemd-boot"
    elif [[ -f /etc/default/grub ]]; then
        echo "grub"
    else
        echo "unknown"
    fi
}
BOOTLOADER=$(detect_bootloader)
DRIVER_INSTALLED=""

info "Distro: $DISTRO | Bootloader: $BOOTLOADER"

# ── Tắt display manager nếu NVIDIA đang chạy ────────────────
stop_display_manager() {
    if lsmod | grep -q "^nvidia"; then
        warn "NVIDIA module đang chạy, cần tắt display manager..."
        for dm in sddm gdm lightdm; do
            systemctl is-active --quiet "$dm" 2>/dev/null && \
                systemctl stop "$dm" 2>/dev/null && info "Đã dừng $dm" || true
        done
        modprobe -r nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
    fi
}

# ════════════════════════════════════════════════════════════
# ARCH / ARCH-BASED (CachyOS, Manjaro, EndeavourOS, Garuda)
# ════════════════════════════════════════════════════════════
install_arch() {
    step "[Arch] Bật multilib + ParallelDownloads"
    PACMAN_CONF="/etc/pacman.conf"
    if ! grep -q "^\[multilib\]" "$PACMAN_CONF"; then
        sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' "$PACMAN_CONF"
        grep -q "^\[multilib\]" "$PACMAN_CONF" || \
            printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$PACMAN_CONF"
        ok "Đã bật multilib"
    else
        info "multilib đã bật"
    fi
    grep -q "^#ParallelDownloads" "$PACMAN_CONF" && \
        sed -i 's/^#ParallelDownloads/ParallelDownloads/' "$PACMAN_CONF"
    pacman -Sy --noconfirm

    step "[Arch] Cài yay"
    if ! command -v yay &>/dev/null; then
        pacman -S --noconfirm --needed git base-devel
        YAY_TMP=$(mktemp -d)
        git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$YAY_TMP"
        cd "$YAY_TMP" && sudo -u "$REAL_USER" makepkg -si --noconfirm
        cd / && rm -rf "$YAY_TMP"
        command -v yay &>/dev/null && ok "Đã cài yay" || warn "yay thất bại"
    else
        info "yay đã cài"
    fi

    step "[Arch] Gỡ driver cũ"
    OLD_PKGS=()
    for pkg in nvidia nvidia-dkms nvidia-open nvidia-open-dkms; do
        pacman -Q "$pkg" &>/dev/null && OLD_PKGS+=("$pkg")
    done
    [[ ${#OLD_PKGS[@]} -gt 0 ]] && \
        pacman -Rdd --noconfirm "${OLD_PKGS[@]}" 2>/dev/null || true

    step "[Arch] Cài NVIDIA driver"
    UTILS=(nvidia-utils lib32-nvidia-utils nvidia-settings)
    if pacman -S --noconfirm --needed nvidia-open "${UTILS[@]}" 2>/dev/null; then
        DRIVER_INSTALLED="nvidia-open"
    elif pacman -S --noconfirm --needed nvidia-open-dkms "${UTILS[@]}" 2>/dev/null; then
        DRIVER_INSTALLED="nvidia-open-dkms"
    elif command -v yay &>/dev/null && \
         sudo -u "$REAL_USER" yay -S --noconfirm nvidia-open-beta "${UTILS[@]}"; then
        DRIVER_INSTALLED="nvidia-open-beta"
    else
        err "Cài driver thất bại. Thử tay: pacman -S nvidia-open-dkms"
    fi

    step "[Arch] Cấu hình mkinitcpio"
    MKINITCPIO_CONF="/etc/mkinitcpio.conf"
    NVIDIA_MODS="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
    # Xóa kms khỏi HOOKS
    sed -i 's/\bkms\b//' "$MKINITCPIO_CONF"
    sed -i '/^HOOKS=/s/  / /g' "$MKINITCPIO_CONF"
    # Thêm NVIDIA modules
    CURRENT_MODS=$(grep "^MODULES=(" "$MKINITCPIO_CONF" 2>/dev/null | sed 's/MODULES=(\(.*\))/\1/' || echo "")
    NEEDS_UPDATE=false
    for mod in $NVIDIA_MODS; do
        echo "$CURRENT_MODS" | grep -qw "$mod" || NEEDS_UPDATE=true
    done
    if $NEEDS_UPDATE; then
        if grep -q "^MODULES=(" "$MKINITCPIO_CONF"; then
            sed -i "s/^MODULES=(\(.*\))/MODULES=($NVIDIA_MODS \1)/" "$MKINITCPIO_CONF"
        else
            echo "MODULES=($NVIDIA_MODS)" >> "$MKINITCPIO_CONF"
        fi
        sed -i '/^MODULES=/s/  \+/ /g' "$MKINITCPIO_CONF"
        ok "Đã thêm NVIDIA modules vào MODULES"
    else
        info "NVIDIA modules đã có"
    fi

    step "[Arch] Tạo pacman hook"
    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/nvidia.hook <<EOF
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=$DRIVER_INSTALLED
Target=nvidia-utils

[Action]
Description=Rebuilding initramfs after NVIDIA update...
Depends=mkinitcpio
When=PostTransaction
Exec=/usr/bin/mkinitcpio -P
EOF
    ok "Đã tạo pacman hook"

    step "[Arch] Rebuild initramfs"
    mkinitcpio -P && ok "Initramfs rebuilt"
}

# ════════════════════════════════════════════════════════════
# FEDORA / FEDORA-BASED (Nobara, Ultramarine)
# ════════════════════════════════════════════════════════════
install_fedora() {
    FEDORA_VER=$(rpm -E %fedora)
    info "Fedora version: $FEDORA_VER"

    step "[Fedora] Thêm RPM Fusion repo"
    if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
        dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" \
            || warn "RPM Fusion install lỗi, thử tiếp..."
        ok "Đã thêm RPM Fusion"
    else
        info "RPM Fusion đã có"
    fi

    step "[Fedora] Kiểm tra module đang chạy"
    stop_display_manager

    step "[Fedora] Cài NVIDIA driver"
    # nvidia-open: package chính thức Fedora 41+
    # --allowerasing: giải quyết conflict với nouveau/mesa
    if dnf install -y nvidia-open --allowerasing 2>/dev/null; then
        DRIVER_INSTALLED="nvidia-open"
        ok "Đã cài nvidia-open"
    elif dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda --allowerasing 2>/dev/null; then
        DRIVER_INSTALLED="akmod-nvidia"
        ok "Đã cài akmod-nvidia"
        info "Đợi akmod build kernel module (2-5 phút)..."
        akmods --force 2>/dev/null || true
        modprobe nvidia 2>/dev/null || true
    else
        err "Cài driver thất bại. Thử tay: dnf install nvidia-open --allowerasing"
    fi

    # Cài thêm utils
    dnf install -y nvidia-settings libva-nvidia-driver 2>/dev/null || true

    step "[Fedora] Bật DRM modeset qua grubby"
    if command -v grubby &>/dev/null; then
        if ! grubby --info=ALL 2>/dev/null | grep -q "nvidia-drm.modeset=1"; then
            grubby --update-kernel=ALL --args="nvidia-drm.modeset=1"
            ok "Đã thêm kernel param qua grubby"
        else
            info "nvidia-drm.modeset=1 đã có"
        fi
    fi

    step "[Fedora] Rebuild initramfs (dracut)"
    dracut --force 2>/dev/null && ok "Initramfs rebuilt" || warn "dracut lỗi"
}

# ════════════════════════════════════════════════════════════
# UBUNTU / DEBIAN / PIKAOS / POP!_OS
# ════════════════════════════════════════════════════════════
install_debian() {
    step "[Debian/Ubuntu] Update repos"
    apt-get update -y

    step "[Debian/Ubuntu] Kiểm tra module đang chạy"
    stop_display_manager

    step "[Debian/Ubuntu] Cài NVIDIA driver"

    IS_UBUNTU=false
    [[ "$DISTRO" =~ ^(ubuntu|pop|pikaos|linuxmint|elementary|zorin)$ ]] && IS_UBUNTU=true
    [[ "$DISTRO_LIKE" =~ ubuntu ]] && IS_UBUNTU=true

    if $IS_UBUNTU; then
        # Thử nvidia-open trước
        if apt-cache show nvidia-open &>/dev/null 2>&1; then
            if apt-get install -y nvidia-open 2>/dev/null; then
                DRIVER_INSTALLED="nvidia-open"
                ok "Đã cài nvidia-open"
            fi
        fi
        # Fallback: ubuntu-drivers
        if [[ -z "$DRIVER_INSTALLED" ]] && command -v ubuntu-drivers &>/dev/null; then
            info "Dùng ubuntu-drivers autoinstall..."
            ubuntu-drivers autoinstall 2>/dev/null || true
            # Detect package vừa cài
            DRIVER_INSTALLED=$(dpkg -l | grep "^ii.*nvidia-driver" | awk '{print $2}' | head -1 || echo "nvidia-driver")
        fi
        # Fallback: detect version cao nhất
        if [[ -z "$DRIVER_INSTALLED" ]]; then
            NVIDIA_PKG=$(apt-cache search "^nvidia-driver-[0-9]" 2>/dev/null \
                | awk '{print $1}' | sort -t- -k3 -n | tail -1)
            if [[ -n "$NVIDIA_PKG" ]]; then
                apt-get install -y "$NVIDIA_PKG" nvidia-settings && \
                    DRIVER_INSTALLED="$NVIDIA_PKG" || true
            fi
        fi
    else
        # Debian thuần: thêm non-free
        if ! grep -rq "non-free" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME" || echo "bookworm")
            cat >> /etc/apt/sources.list.d/non-free.list <<EOF
deb http://deb.debian.org/debian $CODENAME main contrib non-free non-free-firmware
EOF
            apt-get update -y
        fi
        if apt-get install -y nvidia-driver firmware-misc-nonfree nvidia-settings 2>/dev/null; then
            DRIVER_INSTALLED="nvidia-driver"
        fi
    fi

    [[ -z "$DRIVER_INSTALLED" ]] && err "Cài driver thất bại."

    step "[Debian/Ubuntu] Rebuild initramfs"
    update-initramfs -u -k all 2>/dev/null && ok "Initramfs rebuilt" || warn "update-initramfs lỗi"
}

# ════════════════════════════════════════════════════════════
# OPENSUSE
# ════════════════════════════════════════════════════════════
install_opensuse() {
    step "[openSUSE] Thêm NVIDIA repo"
    if ! zypper lr 2>/dev/null | grep -q "nvidia"; then
        OPENSUSE_VER=$(. /etc/os-release && echo "$VERSION_ID")
        zypper addrepo --refresh \
            "https://download.nvidia.com/opensuse/leap/${OPENSUSE_VER}" nvidia 2>/dev/null || \
        zypper addrepo --refresh \
            "https://download.nvidia.com/opensuse/tumbleweed" nvidia 2>/dev/null || true
    fi

    stop_display_manager

    step "[openSUSE] Cài NVIDIA driver"
    if zypper --non-interactive install -y \
        nvidia-open-gfxG06 nvidia-open-gfxG06-kmp-default nvidia-utils-gfxG06 2>/dev/null; then
        DRIVER_INSTALLED="nvidia-open-gfxG06"
    else
        err "Cài driver thất bại. Thử tay: zypper install nvidia-open-gfxG06"
    fi

    step "[openSUSE] Rebuild initramfs"
    dracut --force 2>/dev/null && ok "Initramfs rebuilt" || true
}

# ════════════════════════════════════════════════════════════
# ROUTER — Chọn distro
# ════════════════════════════════════════════════════════════
step "Cài driver cho distro: $DISTRO"

case "$DISTRO" in
    arch|cachyos|manjaro|endeavouros|garuda|artix)
        install_arch ;;
    fedora|nobara|ultramarine|bazzite)
        install_fedora ;;
    ubuntu|debian|pop|pikaos|linuxmint|elementary|zorin|kali|raspbian)
        install_debian ;;
    opensuse*|suse*)
        install_opensuse ;;
    *)
        # Thử detect qua ID_LIKE
        if [[ "$DISTRO_LIKE" =~ arch ]]; then
            install_arch
        elif [[ "$DISTRO_LIKE" =~ fedora|rhel ]]; then
            install_fedora
        elif [[ "$DISTRO_LIKE" =~ ubuntu|debian ]]; then
            install_debian
        else
            err "Distro '$DISTRO' chưa hỗ trợ. Được hỗ trợ: Arch, Fedora, Ubuntu/Debian, openSUSE"
        fi ;;
esac

ok "Driver đã cài: $DRIVER_INSTALLED"

# ════════════════════════════════════════════════════════════
# BLACKLIST NOUVEAU (tất cả distro)
# ════════════════════════════════════════════════════════════
step "Blacklist nouveau"
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

# modprobe.d nvidia options
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
ok "Đã tạo modprobe configs"

# ════════════════════════════════════════════════════════════
# BOOTLOADER — kernel param (cho distro chưa xử lý ở trên)
# ════════════════════════════════════════════════════════════
case "$BOOTLOADER" in
    grub)
        GRUB_CFG="/etc/default/grub"
        if [[ -f "$GRUB_CFG" ]] && ! grep -q "nvidia-drm.modeset=1" "$GRUB_CFG"; then
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' "$GRUB_CFG"
            grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || \
            grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
            ok "Đã cập nhật GRUB"
        fi ;;
    systemd-boot)
        for ENTRY in /boot/loader/entries/*.conf; do
            [[ -f "$ENTRY" ]] || continue
            grep -q "nvidia-drm.modeset=1" "$ENTRY" || \
                sed -i '/^options/s/$/ nvidia-drm.modeset=1/' "$ENTRY"
        done
        ok "Đã cập nhật systemd-boot entries" ;;
esac

# ════════════════════════════════════════════════════════════
# NVIDIA SUSPEND/RESUME SERVICES
# ════════════════════════════════════════════════════════════
step "Bật NVIDIA suspend/resume services"
for svc in nvidia-suspend nvidia-resume nvidia-hibernate; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service" && \
        systemctl enable "$svc" 2>/dev/null && ok "Enabled $svc" || true
done

# ════════════════════════════════════════════════════════════
# HYPRLAND CONFIG (nếu có)
# ════════════════════════════════════════════════════════════
NVIDIA_PCI_ID=$(lspci | grep -i nvidia | head -1 | awk '{print $1}')
NVIDIA_DRI_PATH=""
if [[ -d /dev/dri/by-path ]]; then
    MATCH=$(ls /dev/dri/by-path/ 2>/dev/null | grep "${NVIDIA_PCI_ID}-card$" | head -1)
    [[ -n "$MATCH" ]] && NVIDIA_DRI_PATH="/dev/dri/by-path/${MATCH}"
fi

if command -v hyprctl &>/dev/null || [[ -d "$REAL_HOME/.config/hypr" ]]; then
    step "Tạo Hyprland NVIDIA env config"
    HYPR_DIR="$REAL_HOME/.config/hypr"
    mkdir -p "$HYPR_DIR"
    DRM_LINE="${NVIDIA_DRI_PATH:+env = AQ_DRM_DEVICES,${NVIDIA_DRI_PATH}}"
    DRM_LINE="${DRM_LINE:-# env = AQ_DRM_DEVICES,... (tự động điền bởi nvidia-hypr-path.service)}"

    cat > "$HYPR_DIR/nvidia.conf" <<EOF
# NVIDIA env vars cho Hyprland — tạo tự động bởi install.sh
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = GBM_BACKEND,nvidia-drm
env = WLR_NO_HARDWARE_CURSORS,1
env = XCURSOR_SIZE,24
env = ELECTRON_OZONE_PLATFORM_HINT,auto
env = OZONE_PLATFORM,wayland
${DRM_LINE}
EOF
    chown -R "$REAL_USER:$REAL_USER" "$HYPR_DIR"
    ok "Đã tạo $HYPR_DIR/nvidia.conf"

    HYPR_MAIN="$HYPR_DIR/hyprland.conf"
    if [[ -f "$HYPR_MAIN" ]] && ! grep -q "nvidia.conf" "$HYPR_MAIN"; then
        echo -e "\nsource = ~/.config/hypr/nvidia.conf" >> "$HYPR_MAIN"
        ok "Đã source nvidia.conf vào hyprland.conf"
    fi

    # Post-boot service tự điền AQ_DRM_DEVICES
    cat > /usr/local/bin/nvidia-hypr-path.sh <<SHEOF
#!/usr/bin/env bash
MATCH=\$(ls /dev/dri/by-path/ 2>/dev/null | grep "${NVIDIA_PCI_ID}-card\$" | head -1)
[[ -z "\$MATCH" ]] && exit 0
FULL_PATH="/dev/dri/by-path/\${MATCH}"
CONF="${HYPR_DIR}/nvidia.conf"
if grep -q "AQ_DRM_DEVICES" "\$CONF" 2>/dev/null; then
    sed -i "s|.*AQ_DRM_DEVICES.*|env = AQ_DRM_DEVICES,\${FULL_PATH}|" "\$CONF"
else
    echo "env = AQ_DRM_DEVICES,\${FULL_PATH}" >> "\$CONF"
fi
echo "[nvidia-hypr-path] AQ_DRM_DEVICES = \$FULL_PATH"
SHEOF
    chmod +x /usr/local/bin/nvidia-hypr-path.sh

    cat > /etc/systemd/system/nvidia-hypr-path.service <<'SVCEOF'
[Unit]
Description=Update Hyprland NVIDIA DRI path
After=systemd-udev-settle.service dev-dri.device
Wants=systemd-udev-settle.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/nvidia-hypr-path.sh
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl enable nvidia-hypr-path.service 2>/dev/null
    ok "Đã tạo nvidia-hypr-path.service"
fi

# ════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════
DRM_STATUS=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo "N/A — cần reboot")

echo ""
echo -e "\033[1m\033[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[32m  ✓ Cài đặt hoàn tất!\033[0m"
echo -e "\033[1m\033[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""
echo -e "  Distro:   \033[0;36m${DISTRO}\033[0m"
echo -e "  GPU:      \033[0;36m${GPU_NAME}\033[0m"
echo -e "  Driver:   \033[0;36m${DRIVER_INSTALLED}\033[0m"
echo -e "  Kernel:   \033[0;36m${CURRENT_KERNEL}\033[0m"
echo -e "  Boot:     \033[0;36m${BOOTLOADER}\033[0m"
echo -e "  DRM:      \033[0;36m${DRM_STATUS}\033[0m"
[[ -n "$NVIDIA_DRI_PATH" ]] && echo -e "  DRI:      \033[0;36m${NVIDIA_DRI_PATH}\033[0m"
echo ""
echo -e "  \033[1mSau reboot verify:\033[0m"
echo -e "  \033[0;36mnvidia-smi\033[0m"
echo -e "  \033[0;36mcat /sys/module/nvidia_drm/parameters/modeset\033[0m  → Y"
echo -e "  \033[0;36mcat /sys/module/nvidia_drm/parameters/fbdev\033[0m    → Y"
echo ""
echo -e "  \033[1mDistro hỗ trợ:\033[0m Arch · CachyOS · Manjaro · Fedora · Nobara"
echo -e "               Ubuntu · Debian · PikaOS · Pop!_OS · openSUSE"
echo ""

read -rp "$(echo -e "\033[1;33mReboot ngay? [Y/n]: \033[0m")" REBOOT_NOW
[[ "$REBOOT_NOW" =~ ^[Nn]$ ]] && echo "Nhớ reboot: sudo reboot" || reboot
