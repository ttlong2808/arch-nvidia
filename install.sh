#!/usr/bin/env bash
# ============================================================
#  NVIDIA RTX 5060 Ti - Arch Linux Driver Setup
#  Supports: KDE Plasma + Hyprland (Wayland)
#  Usage: curl -fsSL https://get.tlprox.pro.vn/install.sh | sudo bash
# ============================================================

set -uo pipefail  # Bỏ -e để tự xử lý lỗi từng bước

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()   { echo -e "${RED}[ERR]${RESET}   $*"; exit 1; }
step()  { echo -e "\n${BOLD}${GREEN}==>${RESET}${BOLD} $*${RESET}"; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Chạy script với sudo: sudo bash install.sh"

# ── Detect bootloader ────────────────────────────────────────
detect_bootloader() {
    if [[ -d /boot/loader/entries ]] && ls /boot/loader/entries/*.conf &>/dev/null; then
        echo "systemd-boot"
    elif [[ -f /etc/default/grub ]]; then
        echo "grub"
    else
        echo "unknown"
    fi
}

BOOTLOADER=$(detect_bootloader)
info "Bootloader detected: $BOOTLOADER"

# ── Detect real user (khi chạy qua sudo) ────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
info "User: $REAL_USER | Home: $REAL_HOME"

# ════════════════════════════════════════════════════════════
step "1/8  Bật multilib repo (cần cho lib32-nvidia-utils)"
# ════════════════════════════════════════════════════════════
PACMAN_CONF="/etc/pacman.conf"

if grep -q "^\[multilib\]" "$PACMAN_CONF"; then
    info "multilib đã được bật"
else
    # Bỏ comment [multilib] section nếu đang bị comment
    sed -i '/^#\[multilib\]/{
        s/^#//
        n
        s/^#//
    }' "$PACMAN_CONF"

    if grep -q "^\[multilib\]" "$PACMAN_CONF"; then
        ok "Đã bật multilib repo"
    else
        # Thêm mới nếu không tìm thấy
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$PACMAN_CONF"
        ok "Đã thêm multilib repo vào pacman.conf"
    fi
fi

info "Đang sync package database..."
pacman -Sy --noconfirm

# ════════════════════════════════════════════════════════════
step "2/8  Gỡ driver NVIDIA cũ (nếu có)"
# ════════════════════════════════════════════════════════════
OLD_PKGS=()
for pkg in nvidia nvidia-dkms nvidia-open nvidia-open-dkms; do
    pacman -Q "$pkg" &>/dev/null && OLD_PKGS+=("$pkg")
done

if [[ ${#OLD_PKGS[@]} -gt 0 ]]; then
    warn "Đang gỡ: ${OLD_PKGS[*]}"
    pacman -Rdd --noconfirm "${OLD_PKGS[@]}" 2>/dev/null || true
    ok "Đã gỡ driver cũ"
else
    info "Không có driver cũ cần gỡ"
fi

# ════════════════════════════════════════════════════════════
step "3/8  Cài NVIDIA driver"
# ════════════════════════════════════════════════════════════
# RTX 5060 Ti cần nvidia-open-dkms (open kernel module)
# nvidia-open chỉ dùng cho kernel linux/linux-lts mặc định
# nvidia-open-dkms dùng cho mọi kernel (an toàn hơn)

NVIDIA_UTILS=(nvidia-utils lib32-nvidia-utils nvidia-settings)

# Thử nvidia-open trước (cho kernel linux chuẩn)
info "Thử cài nvidia-open..."
if pacman -S --noconfirm --needed nvidia-open "${NVIDIA_UTILS[@]}" 2>/dev/null; then
    ok "Đã cài nvidia-open"
else
    # Fallback: nvidia-open-dkms (cho custom kernel)
    warn "nvidia-open thất bại, thử nvidia-open-dkms..."
    if pacman -S --noconfirm --needed nvidia-open-dkms "${NVIDIA_UTILS[@]}" 2>/dev/null; then
        ok "Đã cài nvidia-open-dkms"
    else
        err "Cài driver thất bại! Chạy tay: sudo pacman -S nvidia-open-dkms nvidia-utils lib32-nvidia-utils"
    fi
fi

# Cài yay nếu chưa có (cần cho AUR fallback)
if ! command -v yay &>/dev/null; then
    info "Cài yay (AUR helper)..."
    pacman -S --noconfirm --needed git base-devel 2>/dev/null || true
    TMPDIR=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$TMPDIR/yay" 2>/dev/null
    cd "$TMPDIR/yay"
    sudo -u "$REAL_USER" makepkg -si --noconfirm 2>/dev/null && ok "Đã cài yay" || warn "Không cài được yay"
    cd /
    rm -rf "$TMPDIR"
fi

# ════════════════════════════════════════════════════════════
step "4/8  Blacklist module nouveau"
# ════════════════════════════════════════════════════════════
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
ok "Đã tạo /etc/modprobe.d/blacklist-nouveau.conf"

# ════════════════════════════════════════════════════════════
step "5/8  Bật DRM kernel mode setting"
# ════════════════════════════════════════════════════════════
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
ok "Đã tạo /etc/modprobe.d/nvidia.conf"

# Thêm kernel parameter theo bootloader
case "$BOOTLOADER" in
    grub)
        GRUB_CFG="/etc/default/grub"
        if grep -q "nvidia-drm.modeset=1" "$GRUB_CFG"; then
            info "nvidia-drm.modeset=1 đã có trong GRUB"
        else
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' "$GRUB_CFG"
            grub-mkconfig -o /boot/grub/grub.cfg
            ok "Đã cập nhật GRUB"
        fi
        ;;
    systemd-boot)
        ENTRY_FILE=$(ls /boot/loader/entries/*.conf 2>/dev/null | head -1)
        if [[ -n "$ENTRY_FILE" ]]; then
            if grep -q "nvidia-drm.modeset=1" "$ENTRY_FILE"; then
                info "nvidia-drm.modeset=1 đã có trong boot entry"
            else
                sed -i '/^options/s/$/ nvidia-drm.modeset=1/' "$ENTRY_FILE"
                ok "Đã thêm kernel param vào $ENTRY_FILE"
            fi
        else
            warn "Không tìm thấy boot entry. Thêm tay: nvidia-drm.modeset=1"
        fi
        ;;
    *)
        warn "Bootloader không xác định. Thêm tay kernel param: nvidia-drm.modeset=1"
        ;;
esac

# ════════════════════════════════════════════════════════════
step "6/8  Bật NVIDIA systemd services (suspend/resume)"
# ════════════════════════════════════════════════════════════
for svc in nvidia-suspend nvidia-resume nvidia-hibernate; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
        systemctl enable "$svc" 2>/dev/null && ok "Enabled $svc" || warn "Không enable được $svc"
    fi
done

# ════════════════════════════════════════════════════════════
step "7/8  Tạo Hyprland env config cho NVIDIA"
# ════════════════════════════════════════════════════════════
HYPR_DIR="$REAL_HOME/.config/hypr"
mkdir -p "$HYPR_DIR"

cat > "$HYPR_DIR/nvidia.conf" <<'EOF'
# NVIDIA env vars cho Hyprland — được tạo tự động bởi install.sh
# Đã được source tự động vào hyprland.conf

env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = GBM_BACKEND,nvidia-drm
env = WLR_NO_HARDWARE_CURSORS,1
env = ELECTRON_OZONE_PLATFORM_HINT,auto
env = NIXOS_OZONE_WL,1
EOF

chown "$REAL_USER:$REAL_USER" "$HYPR_DIR/nvidia.conf"
ok "Đã tạo $HYPR_DIR/nvidia.conf"

# Source vào hyprland.conf nếu chưa có
HYPR_MAIN="$HYPR_DIR/hyprland.conf"
if [[ -f "$HYPR_MAIN" ]]; then
    if ! grep -q "nvidia.conf" "$HYPR_MAIN"; then
        echo -e "\nsource = ~/.config/hypr/nvidia.conf" >> "$HYPR_MAIN"
        ok "Đã thêm source nvidia.conf vào hyprland.conf"
    else
        info "hyprland.conf đã source nvidia.conf"
    fi
else
    warn "Chưa có hyprland.conf. Khi tạo, thêm: source = ~/.config/hypr/nvidia.conf"
fi

# ════════════════════════════════════════════════════════════
step "8/8  Rebuild initramfs"
# ════════════════════════════════════════════════════════════
mkinitcpio -P
ok "Initramfs đã được rebuild"

# ════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  ✓ Cài đặt hoàn tất!${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}Sau khi reboot, kiểm tra:${RESET}"
echo -e "  ${CYAN}nvidia-smi${RESET}                  → thông tin card"
echo -e "  ${CYAN}lspci -k | grep -A3 NVIDIA${RESET}  → kernel module"
echo -e "  ${CYAN}cat /proc/driver/nvidia/version${RESET} → driver version"
echo ""
echo -e "  ${BOLD}Cấu hình 2 màn hình (Hyprland):${RESET}"
echo -e "  ${CYAN}hyprctl monitors${RESET}  → xem tên monitor"
echo -e "  Thêm vào hyprland.conf:"
echo -e "  ${CYAN}monitor=DP-1,2560x1440@144,0x0,1${RESET}"
echo -e "  ${CYAN}monitor=HDMI-A-1,1920x1080@60,2560x0,1${RESET}"
echo ""
echo -e "  ${BOLD}Cấu hình 2 màn hình (KDE Plasma):${RESET}"
echo -e "  System Settings → Display and Monitor"
echo ""

read -rp "$(echo -e "${YELLOW}Reboot ngay? [y/N]: ${RESET}")" REBOOT_NOW
[[ "$REBOOT_NOW" =~ ^[Yy]$ ]] && reboot || warn "Nhớ reboot: sudo reboot"
