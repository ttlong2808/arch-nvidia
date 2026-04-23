#!/usr/bin/env bash
# ============================================================
#  NVIDIA RTX 5060 Ti - Arch Linux Driver Setup
#  Supports: KDE Plasma + Hyprland (Wayland)
#  Usage: curl -fsSL <raw_url> | bash
# ============================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERR]${RESET}   $*"; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}==>${RESET}${BOLD} $*${RESET}"; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Chạy script với sudo: sudo bash nvidia-5060ti-arch.sh"

# ── Detect bootloader ────────────────────────────────────────
detect_bootloader() {
    if [[ -d /boot/loader/entries ]]; then
        echo "systemd-boot"
    elif [[ -f /boot/grub/grub.cfg ]]; then
        echo "grub"
    else
        echo "unknown"
    fi
}

BOOTLOADER=$(detect_bootloader)
info "Bootloader detected: $BOOTLOADER"

# ────────────────────────────────────────────────────────────
step "1/7  Gỡ driver NVIDIA cũ (nếu có)"
# ────────────────────────────────────────────────────────────
OLD_PKGS=()
for pkg in nvidia nvidia-dkms nvidia-open-dkms; do
    pacman -Q "$pkg" &>/dev/null && OLD_PKGS+=("$pkg")
done

if [[ ${#OLD_PKGS[@]} -gt 0 ]]; then
    warn "Đang gỡ: ${OLD_PKGS[*]}"
    pacman -Rdd --noconfirm "${OLD_PKGS[@]}" 2>/dev/null || true
    ok "Đã gỡ driver cũ"
else
    info "Không có driver cũ cần gỡ"
fi

# ────────────────────────────────────────────────────────────
step "2/7  Cài nvidia-open + utilities"
# ────────────────────────────────────────────────────────────
info "Đang cập nhật danh sách package..."
pacman -Sy --noconfirm

NVIDIA_PKGS=(nvidia-open nvidia-utils lib32-nvidia-utils nvidia-settings)
info "Cài: ${NVIDIA_PKGS[*]}"

if pacman -S --noconfirm "${NVIDIA_PKGS[@]}"; then
    ok "Cài driver thành công"
else
    warn "nvidia-open không có trong repo stable, thử nvidia-open-dkms..."
    pacman -S --noconfirm nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
        || err "Cài driver thất bại. Thử AUR: yay -S nvidia-open-beta"
fi

# ────────────────────────────────────────────────────────────
step "3/7  Blacklist module nouveau"
# ────────────────────────────────────────────────────────────
BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
cat > "$BLACKLIST_FILE" <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
ok "Đã tạo $BLACKLIST_FILE"

# ────────────────────────────────────────────────────────────
step "4/7  Bật DRM kernel mode setting"
# ────────────────────────────────────────────────────────────
MODPROBE_FILE="/etc/modprobe.d/nvidia.conf"
cat > "$MODPROBE_FILE" <<'EOF'
options nvidia-drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
ok "Đã tạo $MODPROBE_FILE"

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
        # Tìm file entry đang dùng
        ENTRY_DIR="/boot/loader/entries"
        ENTRY_FILE=$(ls "$ENTRY_DIR"/*.conf 2>/dev/null | head -1)
        if [[ -n "$ENTRY_FILE" ]]; then
            if grep -q "nvidia-drm.modeset=1" "$ENTRY_FILE"; then
                info "nvidia-drm.modeset=1 đã có trong boot entry"
            else
                sed -i '/^options/s/$/ nvidia-drm.modeset=1/' "$ENTRY_FILE"
                ok "Đã thêm kernel param vào $ENTRY_FILE"
            fi
        else
            warn "Không tìm thấy boot entry. Thêm tay: nvidia-drm.modeset=1 vào kernel options"
        fi
        ;;
    *)
        warn "Không tự động thêm kernel param được. Thêm tay: nvidia-drm.modeset=1"
        ;;
esac

# ────────────────────────────────────────────────────────────
step "5/7  Rebuild initramfs"
# ────────────────────────────────────────────────────────────
mkinitcpio -P
ok "Initramfs đã được rebuild"

# ────────────────────────────────────────────────────────────
step "6/7  Tạo Hyprland env config cho NVIDIA"
# ────────────────────────────────────────────────────────────
HYPR_CONF_DIR=""
# Tìm home dir của user thực (không phải root khi sudo)
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" ]]; then
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    HYPR_CONF_DIR="$REAL_HOME/.config/hypr"
fi

if [[ -n "$HYPR_CONF_DIR" ]]; then
    mkdir -p "$HYPR_CONF_DIR"
    NVIDIA_ENV_FILE="$HYPR_CONF_DIR/nvidia.conf"
    cat > "$NVIDIA_ENV_FILE" <<'EOF'
# NVIDIA environment variables for Hyprland
# Source this file in hyprland.conf:
#   source = ~/.config/hypr/nvidia.conf

env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = GBM_BACKEND,nvidia-drm
env = __NV_PRIME_RENDER_OFFLOAD,1
env = WLR_NO_HARDWARE_CURSORS,1
EOF
    chown "$REAL_USER:$REAL_USER" "$NVIDIA_ENV_FILE"
    ok "Đã tạo $NVIDIA_ENV_FILE"

    # Kiểm tra hyprland.conf có source file này chưa
    HYPR_MAIN="$HYPR_CONF_DIR/hyprland.conf"
    if [[ -f "$HYPR_MAIN" ]]; then
        if ! grep -q "nvidia.conf" "$HYPR_MAIN"; then
            echo -e "\nsource = ~/.config/hypr/nvidia.conf" >> "$HYPR_MAIN"
            ok "Đã thêm source nvidia.conf vào hyprland.conf"
        else
            info "hyprland.conf đã source nvidia.conf rồi"
        fi
    else
        warn "Chưa có hyprland.conf. Thêm tay: source = ~/.config/hypr/nvidia.conf"
    fi
else
    warn "Không xác định được home dir. Tự thêm env vars vào hyprland.conf"
fi

# ────────────────────────────────────────────────────────────
step "7/7  Tóm tắt"
# ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  ✓ Cài đặt hoàn tất!${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}Sau khi reboot, kiểm tra:${RESET}"
echo -e "  ${CYAN}nvidia-smi${RESET}               → xem thông tin card"
echo -e "  ${CYAN}lspci -k | grep -A3 NVIDIA${RESET} → xem kernel module"
echo ""
echo -e "  ${BOLD}Cấu hình 2 màn hình (Hyprland):${RESET}"
echo -e "  ${CYAN}hyprctl monitors${RESET}         → xem tên monitor"
echo -e "  Thêm vào hyprland.conf:"
echo -e "  ${CYAN}monitor=DP-1,2560x1440@144,0x0,1${RESET}"
echo -e "  ${CYAN}monitor=HDMI-A-1,1920x1080@60,2560x0,1${RESET}"
echo ""
echo -e "  ${BOLD}Cấu hình 2 màn hình (KDE Plasma):${RESET}"
echo -e "  System Settings → Display and Monitor"
echo ""

read -rp "$(echo -e "${YELLOW}Reboot ngay bây giờ? [y/N]: ${RESET}")" REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    info "Đang reboot..."
    reboot
else
    warn "Nhớ reboot trước khi dùng: sudo reboot"
fi
