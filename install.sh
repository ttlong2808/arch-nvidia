#!/usr/bin/env bash
# ============================================================
#  NVIDIA RTX 5060 Ti - Arch Linux Driver Setup
#  Supports: KDE Plasma + Hyprland (Wayland)
#  Based on: https://wiki.archlinux.org/title/NVIDIA
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

REAL_USER="${SUDO_USER:-}"
[[ -z "$REAL_USER" ]] && err "Chạy bằng: sudo bash install.sh (không dùng sudo su)"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
info "User: $REAL_USER | Home: $REAL_HOME"

if ! lspci | grep -qi nvidia; then
    err "Không phát hiện NVIDIA card! Kiểm tra lại phần cứng."
fi
GPU_NAME=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
info "Phát hiện GPU: $GPU_NAME"

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
CURRENT_KERNEL=$(uname -r)
info "Bootloader: $BOOTLOADER | Kernel: $CURRENT_KERNEL"

# ════════════════════════════════════════════════════════════
step "1/10  Bật multilib repo + ParallelDownloads"
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
step "2/10  Cài yay (AUR helper)"
# ════════════════════════════════════════════════════════════
if command -v yay &>/dev/null; then
    info "yay đã cài"
else
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
step "3/10  Gỡ driver NVIDIA cũ"
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
step "4/10  Cài NVIDIA driver"
# ════════════════════════════════════════════════════════════
# RTX 5060 Ti (Blackwell) bắt buộc open kernel module
# nvidia-open     → kernel linux/linux-lts chuẩn
# nvidia-open-dkms → custom kernel (linux-zen, linux-cachyos, v.v.)
NVIDIA_UTILS=(nvidia-utils lib32-nvidia-utils nvidia-settings)
DRIVER_INSTALLED=""

info "Thử cài nvidia-open..."
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
                err "Tất cả driver đều thất bại. Kiểm tra kết nối mạng."
            fi
        else
            err "Cài driver thất bại. Chạy tay: pacman -S nvidia-open-dkms nvidia-utils lib32-nvidia-utils"
        fi
    fi
fi
info "Driver: $DRIVER_INSTALLED"

# ════════════════════════════════════════════════════════════
step "5/10  Blacklist nouveau"
# ════════════════════════════════════════════════════════════
# nvidia-utils đã tự blacklist nouveau khi reboot
# Thêm file này để đảm bảo nouveau không load trong early boot
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
ok "Đã blacklist nouveau"

# Xóa kms khỏi HOOKS để nouveau không load trong initramfs
# Arch Wiki: "remove kms from HOOKS array in /etc/mkinitcpio.conf"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
if grep -q "^HOOKS=.*\bkms\b" "$MKINITCPIO_CONF"; then
    sed -i 's/\(HOOKS=([^)]*\)\bkms\b/\1/' "$MKINITCPIO_CONF"
    # Dọn double space nếu có
    sed -i '/^HOOKS=/s/  / /g' "$MKINITCPIO_CONF"
    ok "Đã xóa kms khỏi HOOKS (ngăn nouveau load sớm)"
else
    info "kms không có trong HOOKS hoặc đã được xóa"
fi

if lsmod | grep -q "^nouveau"; then
    modprobe -r nouveau 2>/dev/null && info "Đã unload nouveau" || \
        warn "Không unload được nouveau — có hiệu lực sau reboot"
fi

# ════════════════════════════════════════════════════════════
step "6/10  Thêm NVIDIA modules vào initramfs"
# ════════════════════════════════════════════════════════════
# Arch Wiki: thêm nvidia nvidia_modeset nvidia_uvm nvidia_drm vào MODULES
# để đảm bảo load trước display manager, tránh black screen
NVIDIA_MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"

if grep -q "^MODULES=(" "$MKINITCPIO_CONF"; then
    CURRENT_MODULES=$(grep "^MODULES=(" "$MKINITCPIO_CONF" | sed 's/MODULES=(\(.*\))/\1/')
    NEEDS_UPDATE=false

    for mod in $NVIDIA_MODULES; do
        if ! echo "$CURRENT_MODULES" | grep -qw "$mod"; then
            NEEDS_UPDATE=true
            break
        fi
    done

    if $NEEDS_UPDATE; then
        # Thêm vào đầu MODULES array
        sed -i "s/^MODULES=(\(.*\))/MODULES=($NVIDIA_MODULES \1)/" "$MKINITCPIO_CONF"
        # Dọn double space
        sed -i '/^MODULES=/s/  \+/ /g' "$MKINITCPIO_CONF"
        ok "Đã thêm NVIDIA modules vào /etc/mkinitcpio.conf"
    else
        info "NVIDIA modules đã có trong MODULES"
    fi
else
    # Không tìm thấy dòng MODULES, thêm mới
    echo "MODULES=($NVIDIA_MODULES)" >> "$MKINITCPIO_CONF"
    ok "Đã thêm MODULES vào mkinitcpio.conf"
fi

info "MODULES hiện tại: $(grep '^MODULES=' $MKINITCPIO_CONF)"

# ════════════════════════════════════════════════════════════
step "7/10  Bật DRM kernel mode setting"
# ════════════════════════════════════════════════════════════
# Driver >= 560 tự bật modeset=1, nhưng vẫn set để chắc chắn
# NVreg_PreserveVideoMemoryAllocations=1 cần cho suspend/resume
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
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
            [[ -f "$ENTRY" ]] || continue
            if grep -q "nvidia-drm.modeset=1" "$ENTRY"; then
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
step "8/10  Tạo pacman hook tự rebuild initramfs khi update driver"
# ════════════════════════════════════════════════════════════
# Arch Wiki: tạo hook để mkinitcpio -P chạy tự động sau mỗi lần
# NVIDIA driver được install/upgrade/remove
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
Description=Rebuilding initramfs after NVIDIA driver update...
Depends=mkinitcpio
When=PostTransaction
Exec=/usr/bin/mkinitcpio -P
EOF
ok "Đã tạo /etc/pacman.d/hooks/nvidia.hook"

# ════════════════════════════════════════════════════════════
step "9/10  Detect PCI path + Tạo Hyprland env config"
# ════════════════════════════════════════════════════════════
NVIDIA_PCI_ID=$(lspci | grep -i nvidia | head -1 | awk '{print $1}')
info "NVIDIA PCI ID: $NVIDIA_PCI_ID"

NVIDIA_DRI_PATH=""
if [[ -d /dev/dri/by-path ]]; then
    MATCH=$(ls /dev/dri/by-path/ 2>/dev/null \
        | grep "${NVIDIA_PCI_ID}-card$" | head -1)
    if [[ -n "$MATCH" ]]; then
        NVIDIA_DRI_PATH="/dev/dri/by-path/${MATCH}"
        ok "DRI path: $NVIDIA_DRI_PATH"
    fi
fi
[[ -z "$NVIDIA_DRI_PATH" ]] && warn "DRI path chưa sẵn sàng — sẽ tự cập nhật sau reboot"

# Tạo Hyprland nvidia.conf
HYPR_DIR="$REAL_HOME/.config/hypr"
mkdir -p "$HYPR_DIR"

if [[ -n "$NVIDIA_DRI_PATH" ]]; then
    DRM_LINE="env = AQ_DRM_DEVICES,${NVIDIA_DRI_PATH}"
else
    DRM_LINE="# env = AQ_DRM_DEVICES,/dev/dri/by-path/... (tự động điền bởi nvidia-hypr-path.service)"
fi

cat > "$HYPR_DIR/nvidia.conf" <<EOF
# NVIDIA env vars cho Hyprland
# Tạo tự động bởi install.sh — based on wiki.hyprland.org/Nvidia
# Chạy lại install.sh để cập nhật

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

# Post-boot service tự cập nhật AQ_DRM_DEVICES
STORED_PCI="$NVIDIA_PCI_ID"
STORED_CONF="$HYPR_DIR/nvidia.conf"

cat > /usr/local/bin/nvidia-hypr-path.sh <<SHEOF
#!/usr/bin/env bash
NVIDIA_PCI="${STORED_PCI}"
NVIDIA_CONF="${STORED_CONF}"

MATCH=\$(ls /dev/dri/by-path/ 2>/dev/null | grep "\${NVIDIA_PCI}-card\$" | head -1)

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

# ════════════════════════════════════════════════════════════
step "10/10  Bật NVIDIA services + Rebuild initramfs"
# ════════════════════════════════════════════════════════════
# Arch Wiki: bật suspend/resume services để tránh màn đen sau wake
for svc in nvidia-suspend nvidia-resume nvidia-hibernate; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        systemctl enable "$svc" 2>/dev/null && ok "Enabled $svc" || true
    fi
done

info "Rebuild initramfs (1-2 phút)..."
mkinitcpio -P
ok "Initramfs đã rebuild"

# ════════════════════════════════════════════════════════════
# Verify DRM sau khi cài
# ════════════════════════════════════════════════════════════
info "Kiểm tra DRM modeset..."
DRM_STATUS=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo "N/A (cần reboot)")
info "DRM modeset: $DRM_STATUS"

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
echo -e "  DRM:      \033[0;36m${DRM_STATUS}\033[0m"
[[ -n "$NVIDIA_DRI_PATH" ]] && echo -e "  DRI:      \033[0;36m${NVIDIA_DRI_PATH}\033[0m"
echo ""
echo -e "  \033[1mSau reboot, verify:\033[0m"
echo -e "  \033[0;36mnvidia-smi\033[0m"
echo -e "  \033[0;36mcat /sys/module/nvidia_drm/parameters/modeset\033[0m  → phải ra Y"
echo -e "  \033[0;36mcat /sys/module/nvidia_drm/parameters/fbdev\033[0m    → phải ra Y"
echo -e "  \033[0;36mlspci -k | grep -A3 -i nvidia\033[0m"
echo -e "  \033[0;36mls /dev/dri/by-path/\033[0m"
echo ""
echo -e "  \033[1mPacman hook đã tạo:\033[0m"
echo -e "  /etc/pacman.d/hooks/nvidia.hook → tự rebuild initramfs khi update driver"
echo ""
echo -e "  \033[1mHyprland config:\033[0m"
echo -e "  \033[0;36m~/.config/hypr/nvidia.conf\033[0m"
echo ""

read -rp "$(echo -e "\033[1;33mReboot ngay? [Y/n]: \033[0m")" REBOOT_NOW
[[ "$REBOOT_NOW" =~ ^[Nn]$ ]] && echo "Nhớ reboot: sudo reboot" || reboot
