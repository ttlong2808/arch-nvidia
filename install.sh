#!/usr/bin/env bash
# ============================================================
#  NVIDIA RTX 5060 Ti - Arch Linux Driver Setup
#  Supports: KDE Plasma + Hyprland (Wayland)
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
[[ $EUID -ne 0 ]] && err "Chạy script với sudo: sudo bash install.sh"

# Detect real user
REAL_USER="${SUDO_USER:-}"
[[ -z "$REAL_USER" ]] && err "Chạy bằng: sudo bash install.sh (không dùng sudo su)"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
info "User: $REAL_USER | Home: $REAL_HOME"

# Kiểm tra NVIDIA card có tồn tại không
if ! lspci | grep -qi nvidia; then
    err "Không phát hiện NVIDIA card! Kiểm tra lại phần cứng."
fi
GPU_NAME=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
info "Phát hiện GPU: $GPU_NAME"

# Detect bootloader
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
info "Bootloader: $BOOTLOADER"

CURRENT_KERNEL=$(uname -r)
info "Kernel: $CURRENT_KERNEL"

# ════════════════════════════════════════════════════════════
step "1/9  Bật multilib repo"
# ════════════════════════════════════════════════════════════
PACMAN_CONF="/etc/pacman.conf"

if grep -q "^\[multilib\]" "$PACMAN_CONF"; then
    info "multilib đã bật"
else
    sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' "$PACMAN_CONF"
    if grep -q "^\[multilib\]" "$PACMAN_CONF"; then
        ok "Đã bật multilib"
    else
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$PACMAN_CONF"
        ok "Đã thêm multilib vào pacman.conf"
    fi
fi

if grep -q "^#ParallelDownloads" "$PACMAN_CONF"; then
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' "$PACMAN_CONF"
    ok "Đã bật ParallelDownloads"
fi

info "Sync package database..."
pacman -Sy --noconfirm

# ════════════════════════════════════════════════════════════
step "2/9  Cài yay (AUR helper)"
# ════════════════════════════════════════════════════════════
if command -v yay &>/dev/null; then
    info "yay đã cài"
else
    info "Cài dependencies..."
    pacman -S --noconfirm --needed git base-devel

    YAY_TMP=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$YAY_TMP"
    cd "$YAY_TMP"
    sudo -u "$REAL_USER" makepkg -si --noconfirm
    cd /
    rm -rf "$YAY_TMP"

    command -v yay &>/dev/null && ok "Đã cài yay" || warn "yay cài thất bại — sẽ dùng pacman"
fi

# ════════════════════════════════════════════════════════════
step "3/9  Gỡ driver NVIDIA cũ"
# ════════════════════════════════════════════════════════════
OLD_PKGS=()
for pkg in nvidia nvidia-dkms nvidia-open nvidia-open-dkms; do
    pacman -Q "$pkg" &>/dev/null && OLD_PKGS+=("$pkg")
done

if [[ ${#OLD_PKGS[@]} -gt 0 ]]; then
    warn "Gỡ: ${OLD_PKGS[*]}"
    pacman -Rdd --noconfirm "${OLD_PKGS[@]}" 2>/dev/null || true
    ok "Đã gỡ driver cũ"
else
    info "Không có driver cũ"
fi

# ════════════════════════════════════════════════════════════
step "4/9  Cài NVIDIA driver"
# ════════════════════════════════════════════════════════════
NVIDIA_UTILS=(nvidia-utils lib32-nvidia-utils nvidia-settings)
DRIVER_INSTALLED=""

info "Thử cài nvidia-open (cho kernel chuẩn)..."
if pacman -S --noconfirm --needed nvidia-open "${NVIDIA_UTILS[@]}" 2>/dev/null; then
    DRIVER_INSTALLED="nvidia-open"
    ok "Đã cài nvidia-open"
else
    warn "nvidia-open thất bại → thử nvidia-open-dkms..."
    if pacman -S --noconfirm --needed nvidia-open-dkms "${NVIDIA_UTILS[@]}" 2>/dev/null; then
        DRIVER_INSTALLED="nvidia-open-dkms"
        ok "Đã cài nvidia-open-dkms"
    else
        if command -v yay &>/dev/null; then
            warn "Thử nvidia-open-beta từ AUR..."
            if sudo -u "$REAL_USER" yay -S --noconfirm nvidia-open-beta "${NVIDIA_UTILS[@]}"; then
                DRIVER_INSTALLED="nvidia-open-beta"
                ok "Đã cài nvidia-open-beta"
            else
                err "Tất cả driver đều thất bại. Kiểm tra kết nối mạng và thử lại."
            fi
        else
            err "Cài driver thất bại. Chạy tay: pacman -S nvidia-open-dkms nvidia-utils lib32-nvidia-utils"
        fi
    fi
fi

info "Driver đã cài: $DRIVER_INSTALLED"

# ════════════════════════════════════════════════════════════
step "5/9  Blacklist nouveau"
# ════════════════════════════════════════════════════════════
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
ok "Đã blacklist nouveau"

if lsmod | grep -q "^nouveau"; then
    modprobe -r nouveau 2>/dev/null && info "Đã unload nouveau" || \
        warn "Không unload được nouveau — có hiệu lực sau reboot"
fi

# ════════════════════════════════════════════════════════════
step "6/9  Bật DRM kernel mode setting"
# ════════════════════════════════════════════════════════════
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
ok "Đã tạo /etc/modprobe.d/nvidia.conf"

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
        for ENTRY in /boot/loader/entries/*.conf; do
            if grep -q "nvidia-drm.modeset=1" "$ENTRY" 2>/dev/null; then
                info "Đã có trong $ENTRY"
            else
                sed -i '/^options/s/$/ nvidia-drm.modeset=1/' "$ENTRY"
                ok "Đã cập nhật $ENTRY"
            fi
        done
        ;;
    *)
        warn "Bootloader không xác định. Thêm tay: nvidia-drm.modeset=1 vào kernel cmdline"
        ;;
esac

# ════════════════════════════════════════════════════════════
step "7/9  Detect PCI path của NVIDIA card"
# ════════════════════════════════════════════════════════════
NVIDIA_PCI_ID=$(lspci | grep -i nvidia | head -1 | awk '{print $1}')
NVIDIA_PCI_FULL="0000:${NVIDIA_PCI_ID}"
info "NVIDIA PCI ID: $NVIDIA_PCI_FULL"

NVIDIA_DRI_PATH=""
if [[ -d /dev/dri/by-path ]]; then
    MATCH=$(ls -la /dev/dri/by-path/ 2>/dev/null \
        | grep "${NVIDIA_PCI_ID}-card" \
        | grep -o 'pci-[^ ]*card' | head -1)
    if [[ -n "$MATCH" ]]; then
        NVIDIA_DRI_PATH="/dev/dri/by-path/${MATCH}"
        ok "DRI path: $NVIDIA_DRI_PATH"
    fi
fi

if [[ -z "$NVIDIA_DRI_PATH" ]]; then
    warn "/dev/dri/by-path chưa sẵn sàng — sẽ tự cập nhật sau reboot qua systemd service"
fi

# ════════════════════════════════════════════════════════════
step "8/9  Tạo Hyprland env config"
# ════════════════════════════════════════════════════════════
HYPR_DIR="$REAL_HOME/.config/hypr"
mkdir -p "$HYPR_DIR"

if [[ -n "$NVIDIA_DRI_PATH" ]]; then
    DRM_LINE="env = AQ_DRM_DEVICES,${NVIDIA_DRI_PATH}"
else
    DRM_LINE="# env = AQ_DRM_DEVICES,/dev/dri/by-path/... (tự động điền bởi nvidia-hypr-path.service)"
fi

cat > "$HYPR_DIR/nvidia.conf" <<EOF
# NVIDIA env vars cho Hyprland
# Tạo tự động bởi install.sh — chạy lại install.sh để cập nhật

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

# Source vào hyprland.conf
HYPR_MAIN="$HYPR_DIR/hyprland.conf"
if [[ -f "$HYPR_MAIN" ]]; then
    if ! grep -q "nvidia.conf" "$HYPR_MAIN"; then
        echo -e "\nsource = ~/.config/hypr/nvidia.conf" >> "$HYPR_MAIN"
        ok "Đã source nvidia.conf vào hyprland.conf"
    else
        info "hyprland.conf đã có source nvidia.conf"
    fi
else
    cat > "$HYPR_MAIN" <<'HYPREOF'
# Hyprland config tối thiểu — tạo tự động bởi install.sh
source = ~/.config/hypr/nvidia.conf

# Monitor — uncomment và chỉnh sau khi chạy: hyprctl monitors
# monitor=DP-1,2560x1440@144,0x0,1
# monitor=HDMI-A-1,1920x1080@60,2560x0,1

misc {
    vfr = true
    vrr = 0
}
HYPREOF
    chown "$REAL_USER:$REAL_USER" "$HYPR_MAIN"
    ok "Đã tạo hyprland.conf tối thiểu"
fi

# ── Post-boot systemd service để tự điền AQ_DRM_DEVICES ─────
# (chạy sau mỗi boot khi /dev/dri/by-path đã sẵn sàng)
SCRIPT_PATH="/usr/local/bin/nvidia-hypr-path.sh"
STORED_PCI="$NVIDIA_PCI_ID"
STORED_CONF="$HYPR_DIR/nvidia.conf"

cat > "$SCRIPT_PATH" <<SHEOF
#!/usr/bin/env bash
NVIDIA_PCI="${STORED_PCI}"
NVIDIA_CONF="${STORED_CONF}"

MATCH=\$(ls -la /dev/dri/by-path/ 2>/dev/null \\
    | grep "\${NVIDIA_PCI}-card" \\
    | grep -o 'pci-[^ ]*card' | head -1)

if [[ -n "\$MATCH" ]]; then
    FULL_PATH="/dev/dri/by-path/\${MATCH}"
    if grep -q "AQ_DRM_DEVICES" "\$NVIDIA_CONF" 2>/dev/null; then
        sed -i "s|.*AQ_DRM_DEVICES.*|env = AQ_DRM_DEVICES,\${FULL_PATH}|" "\$NVIDIA_CONF"
    else
        echo "env = AQ_DRM_DEVICES,\${FULL_PATH}" >> "\$NVIDIA_CONF"
    fi
    echo "[nvidia-hypr-path] AQ_DRM_DEVICES = \$FULL_PATH"
else
    echo "[nvidia-hypr-path] Không tìm thấy DRI path cho PCI \${NVIDIA_PCI}"
fi
SHEOF
chmod +x "$SCRIPT_PATH"

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

# ════════════════════════════════════════════════════════════
step "9/9  Bật NVIDIA services + Rebuild initramfs"
# ════════════════════════════════════════════════════════════
for svc in nvidia-suspend nvidia-resume nvidia-hibernate; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        systemctl enable "$svc" 2>/dev/null && ok "Enabled $svc" || true
    fi
done

info "Rebuild initramfs (1-2 phút)..."
mkinitcpio -P
ok "Initramfs đã rebuild"

# ════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════
echo ""
echo -e "\033[1m\033[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[32m  ✓ Cài đặt hoàn tất!\033[0m"
echo -e "\033[1m\033[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""
echo -e "  GPU:      \033[0;36m${GPU_NAME}\033[0m"
echo -e "  Driver:   \033[0;36m${DRIVER_INSTALLED}\033[0m"
echo -e "  Kernel:   \033[0;36m${CURRENT_KERNEL}\033[0m"
echo -e "  Boot:     \033[0;36m${BOOTLOADER}\033[0m"
[[ -n "$NVIDIA_DRI_PATH" ]] && echo -e "  DRI:      \033[0;36m${NVIDIA_DRI_PATH}\033[0m"
echo ""
echo -e "  \033[1mSau reboot, kiểm tra:\033[0m"
echo -e "  \033[0;36mnvidia-smi\033[0m                    → thông tin card"
echo -e "  \033[0;36mcat /proc/driver/nvidia/version\033[0m → driver version"
echo -e "  \033[0;36mlspci -k | grep -A3 -i nvidia\033[0m  → kernel module"
echo -e "  \033[0;36mls /dev/dri/by-path/\033[0m           → DRI path"
echo ""
echo -e "  \033[1mCấu hình 2 màn hình (Hyprland):\033[0m"
echo -e "  \033[0;36mhyprctl monitors\033[0m  → xem tên & resolution"
echo -e "  Sửa: \033[0;36m~/.config/hypr/hyprland.conf\033[0m"
echo ""

read -rp "$(echo -e "\033[1;33mReboot ngay? [Y/n]: \033[0m")" REBOOT_NOW
[[ "$REBOOT_NOW" =~ ^[Nn]$ ]] && echo "Nhớ reboot: sudo reboot" || reboot
