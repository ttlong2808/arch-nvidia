#!/usr/bin/env bash
# ============================================================
#  remove-de.sh — Xóa toàn bộ Desktop Environment trên Arch
#  Hỗ trợ: KDE Plasma, GNOME, XFCE, COSMIC, Hyprland, Sway
#  Usage: curl -fsSL https://get.tlprox.pro.vn/remove-de.sh | sudo bash
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()   { echo -e "${RED}[ERR]${RESET}   $*"; exit 1; }
step()  { echo -e "\n${BOLD}${GREEN}==>${RESET}${BOLD} $*${RESET}"; }
skip()  { echo -e "${YELLOW}[SKIP]${RESET}  $* (không tìm thấy)"; }

[[ $EUID -ne 0 ]] && err "Chạy với sudo: sudo bash remove-de.sh"

# ── Hàm kiểm tra và gỡ package ──────────────────────────────
remove_pkgs() {
    local label="$1"; shift
    local found=()
    for pkg in "$@"; do
        pacman -Q "$pkg" &>/dev/null && found+=("$pkg")
    done
    if [[ ${#found[@]} -gt 0 ]]; then
        info "Gỡ $label: ${found[*]}"
        pacman -Rdd --noconfirm "${found[@]}" 2>/dev/null || \
        pacman -Rns --noconfirm "${found[@]}" 2>/dev/null || \
        warn "Không thể gỡ một số package của $label, bỏ qua"
        ok "$label đã được gỡ"
    else
        skip "$label"
    fi
}

# ── Kiểm tra package có tồn tại không ───────────────────────
has_any() {
    for pkg in "$@"; do
        pacman -Q "$pkg" &>/dev/null && return 0
    done
    return 1
}

# ============================================================
echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${RED}║         ARCH LINUX — XÓA DESKTOP ENV        ║${RESET}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${RESET}"
echo ""
warn "Script này sẽ XÓA toàn bộ DE được phát hiện trên máy."
warn "Sau khi xóa, bạn sẽ chỉ còn TTY (terminal thuần)."
echo ""
read -rp "$(echo -e "${RED}Bạn chắc chắn muốn tiếp tục? [yes/N]: ${RESET}")" CONFIRM
[[ "$CONFIRM" != "yes" ]] && { info "Đã hủy."; exit 0; }

# ── Detect DE nào đang có ───────────────────────────────────
step "Scanning DE hiện có trên hệ thống..."

DETECTED=()
has_any plasma-desktop kwin kde-applications plasma-meta \
    plasma-workspace kf6-config kcoreaddons && DETECTED+=("KDE Plasma")
has_any gnome gnome-shell gnome-session mutter gdm && DETECTED+=("GNOME")
has_any xfce4 xfce4-session xfwm4 thunar && DETECTED+=("XFCE")
has_any cosmic-session cosmic-comp cosmic-applets && DETECTED+=("COSMIC")
has_any hyprland waybar wofi rofi-wayland swaylock && DETECTED+=("Hyprland/WM")
has_any sway swaybg swaylock swayidle && DETECTED+=("Sway")
has_any lxde lxqt openbox && DETECTED+=("LXDE/LXQt")
has_any cinnamon cinnamon-session && DETECTED+=("Cinnamon")
has_any mate-session-manager mate-panel && DETECTED+=("MATE")
has_any budgie-desktop && DETECTED+=("Budgie")
has_any deepin-session-ui deepin-wm && DETECTED+=("Deepin")

if [[ ${#DETECTED[@]} -eq 0 ]]; then
    info "Không phát hiện DE nào được cài đặt."
    exit 0
fi

echo ""
echo -e "${BOLD}Phát hiện các DE sau:${RESET}"
for de in "${DETECTED[@]}"; do
    echo -e "  ${RED}✗${RESET} $de"
done
echo ""
read -rp "$(echo -e "${YELLOW}Xác nhận xóa tất cả? [yes/N]: ${RESET}")" CONFIRM2
[[ "$CONFIRM2" != "yes" ]] && { info "Đã hủy."; exit 0; }

# ============================================================
step "1 — Dừng display manager"
# ============================================================
for dm in sddm gdm lightdm lxdm xdm greetd; do
    if systemctl is-active --quiet "$dm" 2>/dev/null; then
        info "Dừng $dm..."
        systemctl stop "$dm" 2>/dev/null || true
        systemctl disable "$dm" 2>/dev/null || true
        ok "$dm đã dừng"
    fi
done

# ============================================================
step "2 — Xóa KDE Plasma"
# ============================================================
remove_pkgs "KDE Plasma (core)" \
    plasma-desktop plasma-workspace kwin plasma-meta \
    plasma-wayland-session plasma-x11

remove_pkgs "KDE Plasma (apps)" \
    kde-applications-meta dolphin konsole kate ark \
    okular gwenview spectacle elisa kmail kontact \
    kdepim-meta

remove_pkgs "KDE Plasma (frameworks)" \
    kf6-config kcoreaddons ki18n kservice kwidgetsaddons \
    kwindowsystem kxmlgui knotifications plasma-framework \
    kdebase-runtime

remove_pkgs "KDE Plasma (extra)" \
    plasma-nm plasma-pa plasma-systemmonitor \
    plasma-firewall plasma-browser-integration \
    kscreen colord-kde kdeplasma-addons bluedevil \
    plasma-vault plasma-thunderbolt

remove_pkgs "SDDM" sddm sddm-kcm

# ============================================================
step "3 — Xóa GNOME"
# ============================================================
remove_pkgs "GNOME (core)" \
    gnome gnome-shell gnome-session gnome-control-center \
    mutter gnome-meta

remove_pkgs "GNOME (apps)" \
    gnome-terminal gnome-files nautilus gedit \
    gnome-calculator gnome-calendar eog evince \
    totem gnome-music gnome-photos gnome-maps \
    gnome-weather gnome-clocks gnome-contacts

remove_pkgs "GNOME (extra)" \
    gnome-tweaks gnome-shell-extensions gdm \
    gnome-backgrounds gnome-themes-extra

remove_pkgs "GDM" gdm

# ============================================================
step "4 — Xóa XFCE"
# ============================================================
remove_pkgs "XFCE" \
    xfce4 xfce4-goodies xfce4-session xfwm4 \
    xfdesktop xfce4-panel xfce4-settings thunar \
    xfce4-terminal mousepad ristretto

# ============================================================
step "5 — Xóa COSMIC"
# ============================================================
remove_pkgs "COSMIC" \
    cosmic-session cosmic-comp cosmic-applets \
    cosmic-settings cosmic-files cosmic-terminal \
    cosmic-launcher cosmic-osd cosmic-panel \
    cosmic-bg cosmic-workspaces-epoch

# ============================================================
step "6 — Xóa Hyprland và WM liên quan"
# ============================================================
remove_pkgs "Hyprland" \
    hyprland hyprpaper hypridle hyprlock \
    hyprland-qt-support hyprwayland-scanner \
    xdg-desktop-portal-hyprland

remove_pkgs "Waybar" waybar

remove_pkgs "Launchers" wofi rofi rofi-wayland fuzzel

remove_pkgs "Wayland utils" \
    swaylock swayidle swaybg wlogout \
    wl-clipboard cliphist

remove_pkgs "Notification" dunst mako swaync

# ============================================================
step "7 — Xóa Sway"
# ============================================================
remove_pkgs "Sway" \
    sway swaybg swaylock swayidle \
    sway-contrib xdg-desktop-portal-wlr

# ============================================================
step "8 — Xóa các DE khác"
# ============================================================
remove_pkgs "LXDE/LXQt" lxde lxqt openbox pcmanfm

remove_pkgs "Cinnamon" \
    cinnamon cinnamon-session cinnamon-settings-daemon \
    nemo muffin

remove_pkgs "MATE" \
    mate mate-session-manager mate-panel \
    mate-control-center caja marco

remove_pkgs "Budgie" budgie-desktop budgie-control-center

remove_pkgs "Deepin" deepin-session-ui deepin-wm deepin-file-manager

# ============================================================
step "9 — Xóa display manager còn lại"
# ============================================================
remove_pkgs "Display Managers" \
    sddm gdm lightdm lightdm-gtk-greeter \
    lxdm xdm greetd

# ============================================================
step "10 — Xóa X11 server (nếu muốn)"
# ============================================================
echo ""
read -rp "$(echo -e "${YELLOW}Xóa luôn X11/Xorg? (Wayland vẫn hoạt động độc lập) [y/N]: ${RESET}")" DEL_X11
if [[ "$DEL_X11" =~ ^[Yy]$ ]]; then
    remove_pkgs "Xorg" \
        xorg xorg-server xorg-xinit xorg-apps \
        xf86-input-libinput xf86-video-vesa
    ok "Đã xóa Xorg"
else
    info "Giữ lại Xorg"
fi

# ============================================================
step "11 — Dọn orphan packages"
# ============================================================
echo ""
read -rp "$(echo -e "${YELLOW}Xóa orphaned packages? (khuyến nghị) [Y/n]: ${RESET}")" DEL_ORPHAN
if [[ ! "$DEL_ORPHAN" =~ ^[Nn]$ ]]; then
    ORPHANS=$(pacman -Qdtq 2>/dev/null || true)
    if [[ -n "$ORPHANS" ]]; then
        echo "$ORPHANS" | xargs pacman -Rns --noconfirm 2>/dev/null || true
        ok "Đã xóa orphaned packages"
    else
        info "Không có orphaned packages"
    fi
fi

# ============================================================
step "12 — Dọn package cache"
# ============================================================
read -rp "$(echo -e "${YELLOW}Xóa package cache? [y/N]: ${RESET}")" DEL_CACHE
if [[ "$DEL_CACHE" =~ ^[Yy]$ ]]; then
    pacman -Sc --noconfirm
    ok "Đã xóa cache"
fi

# ============================================================
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  ✓ Hoàn tất! Đã xóa các DE được phát hiện.${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}Bước tiếp theo:${RESET}"
echo -e "  ${CYAN}# Cài HyDE (Hyprland dotfiles)${RESET}"
echo -e "  sudo pacman -S --needed git base-devel"
echo -e "  git clone --depth 1 https://github.com/HyDE-Project/HyDE ~/HyDE"
echo -e "  cd ~/HyDE/Scripts && ./install.sh"
echo ""
echo -e "  ${CYAN}# Hoặc cài lại NVIDIA driver${RESET}"
echo -e "  curl -fsSL https://get.tlprox.pro.vn/install.sh | sudo bash"
echo ""

read -rp "$(echo -e "${YELLOW}Reboot ngay? [y/N]: ${RESET}")" DO_REBOOT
[[ "$DO_REBOOT" =~ ^[Yy]$ ]] && reboot || warn "Nhớ reboot: sudo reboot"
