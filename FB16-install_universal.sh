#!/bin/sh
# ==============================================================================
# IDEMPOTENT INSTALLATION AND CONFIGURATION SCRIPT FOR FREEBSD
# Target: Universal Desktop Deployment (Workstations & Laptops)
# Version: 16.0-CURRENT (Fully Idempotent, Nvidia Fix, SDDM X11, POSIX sh)
# ==============================================================================

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 This script must be run as root (superuser)." 1>&2
    exit 1
fi

# ==============================================================================
# 0. DISCLAIMER AND RISK ACCEPTANCE
# ==============================================================================
bsddialog --title "⚠️ IMPORTANT WARNING ⚠️" \
          --yesno "This script will deeply modify your FreeBSD system:\n\n\
- Installation of numerous system packages and software.\n\
- Critical modification of boot configuration (/boot/loader.conf).\n\
- Adjustments to core kernel parameters (/etc/sysctl.conf).\n\
- Setup of users, GPU drivers, and desktop environments.\n\n\
The author declines any responsibility in case of data loss or instability.\n\n\
Have you backed up your data and do you accept the risks?" 16 75

if [ $? -ne 0 ]; then
    clear
    echo "❌ Installation cancelled by the user. No changes were made."
    exit 0
fi

MENU_OUT=$(mktemp)

# Helper function to append a line cleanly only if it doesn't exist yet
add_line_if_missing() {
    LINE="$1"
    FILE="$2"
    [ ! -f "$FILE" ] && touch "$FILE"
    grep -qF -- "$LINE" "$FILE" || echo "$LINE" >> "$FILE"
}

# Helper function to append kld module cleanly without duplicating
add_kld_module() {
    MOD="$1"
    sysrc -n kld_list | grep -qw "$MOD" || sysrc kld_list+="$MOD"
}

# ==============================================================================
# 1. INTERACTIVE SELECTION MENUS (bsddialog)
# ==============================================================================

# Main Username
bsddialog --title "System User Creation" \
          --inputbox "Enter the main administrator username to create or update:" 10 65 "administrateur" 2> "$MENU_OUT"
MAIN_USER=$(cat "$MENU_OUT")
[ -z "$MAIN_USER" ] && MAIN_USER="administrateur"

# FreeBSD Version Selection Menu
bsddialog --title "FreeBSD Target Version" \
          --menu "Select your installed FreeBSD version branch:" 15 70 3 \
          "1" "FreeBSD 16.0-CURRENT (or main branch)" \
          "2" "FreeBSD 15.x-RELEASE" \
          "3" "FreeBSD 14.x-RELEASE" 2> "$MENU_OUT"
OS_CHOICE=$(cat "$MENU_OUT")

# Machine Type (Desktop vs Laptop)
bsddialog --title "Machine Profile" \
          --menu "Select the type of hardware for power/network optimizations:" 15 70 2 \
          "1" "Desktop / Workstation (Performance focus)" \
          "2" "Laptop / Notebook (Battery, WiFi & Suspend focus)" 2> "$MENU_OUT"
MACHINE_TYPE=$(cat "$MENU_OUT")

# Language Selection Menu
bsddialog --title "System Language" \
          --menu "Select the primary working language:" 15 70 5 \
          "1" "Swiss French (fr_CH.UTF-8)" \
          "2" "French (fr_FR.UTF-8)" \
          "3" "German (de_DE.UTF-8)" \
          "4" "Italian (it_IT.UTF-8)" \
          "5" "Portuguese (pt_PT.UTF-8)" 2> "$MENU_OUT"
LANG_CHOICE=$(cat "$MENU_OUT")

# Keyboard Layout Selection Menu
bsddialog --title "Keyboard Layout" \
          --menu "Select your X11/Graphical keyboard layout:" 17 75 7 \
          "1" "Swiss French (ch fr)" \
          "2" "Swiss German (ch de)" \
          "3" "Swiss Italian (ch it)" \
          "4" "French (fr)" \
          "5" "German (de)" \
          "6" "Italian (it)" \
          "7" "Portuguese (pt)" 2> "$MENU_OUT"
KBD_CHOICE=$(cat "$MENU_OUT")

# CPU Architecture Selection Menu
bsddialog --title "CPU Configuration" \
          --menu "Select your CPU processor architecture:" 15 70 3 \
          "1" "AMD (Ryzen / Threadripper / EPYC)" \
          "2" "Intel (Core / Xeon)" \
          "3" "None / Keep system default" 2> "$MENU_OUT"
CPU_CHOICE=$(cat "$MENU_OUT")

# Graphics Card Selection Menu
bsddialog --title "Video Configuration" \
          --menu "Select your graphics card driver:" 16 75 5 \
          "1" "NVIDIA RTX / Quadro / GTX (Proprietary driver)" \
          "2" "AMD Radeon (Open-source KMS driver)" \
          "3" "Intel Graphics (Open-source KMS driver)" \
          "4" "Framebuffer / Virtual Machine (VMware/VBox/SCFB)" \
          "5" "None / Keep system default" 2> "$MENU_OUT"
GPU_CHOICE=$(cat "$MENU_OUT")

# NVIDIA Sub-menu
NVIDIA_VERSION=""
if [ "$GPU_CHOICE" -eq 1 ]; then
    bsddialog --title "NVIDIA Driver Version" \
              --menu "Select the exact NVIDIA driver version branch:" 15 70 2 \
              "latest" "Latest production driver (nvidia-driver)" \
              "470"    "Version 470 (Legacy branch)" 2> "$MENU_OUT"
    NVIDIA_VERSION=$(cat "$MENU_OUT")
    [ -z "$NVIDIA_VERSION" ] && NVIDIA_VERSION="latest"
fi

# Desktop Environment Selection Menu
bsddialog --title "Desktop Environment" \
          --menu "Select the primary user interface:" 15 70 5 \
          "1" "KDE Plasma 6 (Modern, Wayland & X11)" \
          "2" "XFCE 4 (Lightweight, Stable & X11)" \
          "3" "MATE Desktop (Traditional & X11)" \
          "4" "None (Server setup or manual management)" 2> "$MENU_OUT"
DE_CHOICE=$(cat "$MENU_OUT")

# Optional NASA Theme Menu
THEME_NASA=1
if [ "$DE_CHOICE" -ne 4 ]; then
    bsddialog --title "SDDM Theme Customization" \
              --yesno "Do you want to install and configure the custom NASA SDDM login theme and FreeBSD boot logos?" 10 75
    THEME_NASA=$?
fi

# Software Component Selection Menu
bsddialog --title "Software Selection" \
          --checklist "Choose the components and applications to install:" 20 75 6 \
          "INTERNET" "Firefox, additional fonts, web productivity tools" ON \
          "MEDIA" "VLC, FFmpeg, MPV, Pipewire/Pulse audio stack" ON \
          "VBOX" "VirtualBox (Kernel emulation, devfs & groups)" OFF \
          "XRDP" "Remote Desktop Protocol (RDP) server access" OFF \
          "SAMBA" "Samba network share (Configures /home/share)" OFF 2> "$MENU_OUT"
APP_CHOICES=$(cat "$MENU_OUT")

# Assign variables based on choices
SAMBA_PKG="samba419"
VBOX_PKG="virtualbox-ose"

case "$LANG_CHOICE" in
    1) SYS_LANG="fr_CH.UTF-8"; SYS_LC="fr_CH"; CLASS_NAME="swissfrench" ;;
    2) SYS_LANG="fr_FR.UTF-8"; SYS_LC="fr_FR"; CLASS_NAME="french" ;;
    3) SYS_LANG="de_DE.UTF-8"; SYS_LC="de_DE"; CLASS_NAME="german" ;;
    4) SYS_LANG="it_IT.UTF-8"; SYS_LC="it_IT"; CLASS_NAME="italian" ;;
    5) SYS_LANG="pt_PT.UTF-8"; SYS_LC="pt_PT"; CLASS_NAME="portuguese" ;;
    *) SYS_LANG="fr_CH.UTF-8"; SYS_LC="fr_CH"; CLASS_NAME="swissfrench" ;;
esac

case "$KBD_CHOICE" in
    1) KBD_LAYOUT="ch"; KBD_VARIANT="fr" ;;
    2) KBD_LAYOUT="ch"; KBD_VARIANT="de" ;;
    3) KBD_LAYOUT="ch"; KBD_VARIANT="it" ;;
    4) KBD_LAYOUT="fr"; KBD_VARIANT="" ;;
    5) KBD_LAYOUT="de"; KBD_VARIANT="" ;;
    6) KBD_LAYOUT="it"; KBD_VARIANT="" ;;
    7) KBD_LAYOUT="pt"; KBD_VARIANT="" ;;
    *) KBD_LAYOUT="ch"; KBD_VARIANT="fr" ;;
esac

clear
echo "=========================================================================="
echo "🚀 Updating Package repository..."
echo "=========================================================================="
sed -i '' 's/quarterly/latest/g' /etc/pkg/FreeBSD.conf 2>/dev/null || true
env ASSUME_ALWAYS_YES=YES pkg bootstrap -f
pkg update -f
pkg upgrade -y

# ==============================================================================
# 2. USER CREATION
# ==============================================================================
echo "👤 Setting up user: $MAIN_USER..."
if ! id "$MAIN_USER" >/dev/null 2>&1; then
    pw useradd "$MAIN_USER" -m -G wheel,operator,video -s /bin/sh -c "System Administrator"
else
    pw usermod "$MAIN_USER" -G wheel,operator,video -s /bin/sh
fi

echo "defaultclass=${CLASS_NAME}" > /etc/adduser.conf
pw usermod root -L ${CLASS_NAME}
pw usermod "$MAIN_USER" -L ${CLASS_NAME}

# ==============================================================================
# 3. SYSTEM OPTIMIZATIONS
# ==============================================================================
echo "⚙️  Optimizing boot loader & kernel parameters..."

sysrc -f /boot/loader.conf boot_mute="YES"
sysrc splash_changer_enable="YES"
sysrc rc_startmsgs="NO"
sysrc -f /boot/loader.conf autoboot_delay="3"
sysrc -f /boot/loader.conf aio_load="YES"

# Universal Network/TCP optimizations
add_line_if_missing 'net.inet.tcp.soreceive_stream="1"' /boot/loader.conf
add_line_if_missing 'net.isr.defaultqlimit="2048"' /boot/loader.conf
add_line_if_missing 'net.link.ifqmaxlen="2048"' /boot/loader.conf
add_kld_module "cc_htcp"

# Sysctl Tweaks
add_line_if_missing "kern.ipc.shm_allow_removed=1" /etc/sysctl.conf
add_line_if_missing "kern.ipc.shm_use_phys=1" /etc/sysctl.conf
add_line_if_missing "net.local.stream.recvspace=65536" /etc/sysctl.conf
add_line_if_missing "net.local.stream.sendspace=65536" /etc/sysctl.conf
add_line_if_missing "vfs.usermount=1" /etc/sysctl.conf
add_line_if_missing "hw.kbd.keymap_restrict_change=4" /etc/sysctl.conf

# Silence standard rc messages
if ! grep -q "run_rc_script .*_rc_elem.*> /dev/null" /etc/rc; then
    sed -i '' 's/run_rc_script ${_rc_elem} ${_boot}/run_rc_script ${_rc_elem} ${_boot} > \/dev\/null/g' /etc/rc
fi

# ==============================================================================
# 4. LAPTOP SPECIFIC TUNING
# ==============================================================================
if [ "$MACHINE_TYPE" -eq 2 ]; then
    echo "🔋 Applying Laptop specific optimizations..."
    pkg install -y networkmgr sudo acpi_call
    
    add_line_if_missing 'machdep.hwpstate_pkg_ctrl="0"' /boot/loader.conf
    add_line_if_missing 'hw.pci.do_power_nodriver="3"' /boot/loader.conf
    add_line_if_missing 'vfs.zfs.txg.timeout="10"' /boot/loader.conf
    add_line_if_missing 'hw.snd.latency="7"' /etc/sysctl.conf
    
    sysrc performance_cx_lowest="Cmax"
    sysrc economy_cx_lowest="Cmax"
    add_kld_module "acpi_ibm"
    
    mkdir -p /usr/local/etc/sudoers.d
    if [ ! -f /usr/local/etc/sudoers.d/networkmgr ]; then
        echo "%operator ALL=NOPASSWD: /usr/local/bin/networkmgr" > /usr/local/etc/sudoers.d/networkmgr
        chmod 0440 /usr/local/etc/sudoers.d/networkmgr
    fi
fi

# ==============================================================================
# 5. CPU MANAGEMENT
# ==============================================================================
case "$CPU_CHOICE" in
    1)
        sysrc -f /boot/loader.conf amdtemp_load="YES"
        pkg install -y cpu-microcode
        sysrc -f /boot/loader.conf cpu_microcode_load="YES"
        sysrc -f /boot/loader.conf cpu_microcode_name="/boot/firmware/amd-ucode.bin"
        ;;
    2)
        sysrc -f /boot/loader.conf coretemp_load="YES"
        pkg install -y cpu-microcode
        sysrc -f /boot/loader.conf cpu_microcode_load="YES"
        sysrc -f /boot/loader.conf cpu_microcode_name="/boot/firmware/intel-ucode.bin"
        ;;
esac

# ==============================================================================
# 6. LINUX COMPAT & CORE UTILITIES
# ==============================================================================
echo "🐧 Configuring base components and Linux compatibility..."
sysrc linux_enable="YES"
sysrc linux64_enable="YES"

kldload -n linux 2>/dev/null || true
kldload -n linux64 2>/dev/null || true

pkg install -y linux-rl9 doas unzip wget git htop neofetch python3 bashtop ImageMagick7 smartmontools dbus avahi seatd fusefs-ntfs fusefs-ext2

service linux start 2>/dev/null || true

sysrc smartd_enable="YES"
[ ! -f /usr/local/etc/smartd.conf ] && cp /usr/local/etc/smartd.conf.sample /usr/local/etc/smartd.conf 2>/dev/null || true
sysrc dbus_enable="YES"
sysrc avahi_enable="YES"
sysrc seatd_enable="YES"

add_line_if_missing "proc /proc procfs rw 0 0" /etc/fstab
add_line_if_missing "fdesc /dev/fd fdescfs rw 0 0" /etc/fstab

if ! grep -q "${CLASS_NAME}|" /etc/login.conf; then
    cat << EOF >> /etc/login.conf

${CLASS_NAME}|Localized Users Accounts:\
        :charset=UTF-8:\
        :lang=${SYS_LANG}:\
        :lc_all=${SYS_LC}:\
        :lc_collate=${SYS_LC}:\
        :lc_ctype=${SYS_LC}:\
        :lc_messages=${SYS_LC}:\
        :tc=default:
EOF
    cap_mkdb /etc/login.conf
fi

# ==============================================================================
# 7. HARDWARE RULES (DEVFS) & PRINTERS
# ==============================================================================
echo "🖨️  Configuring hardware rules..."
cat > /etc/devfs.rules << 'EOF'
[localrules=10]
add path 'da*' mode 0660 group operator
add path 'cd*' mode 0660 group operator
add path 'uscanner*' mode 0660 group operator
add path 'xpt*' mode 660 group operator
add path 'pass*' mode 660 group operator
add path 'md*' mode 0660 group operator
add path 'msdosfs/*' mode 0660 group operator
add path 'ext2fs/*' mode 0660 group operator
add path 'ntfs/*' mode 0660 group operator
add path 'usb/*' mode 0660 group operator
add path 'unlpt*' mode 0660 group cups
add path 'lpt*' mode 0660 group cups
add path 'drm/*' mode 0660 group video
add path 'video*' mode 0660 group video
add path 'backlight/*' mode 0660 group operator
EOF
sysrc devfs_system_ruleset="localrules"
add_kld_module "fusefs"
add_kld_module "ext2fs"

# ==============================================================================
# 8. GRAPHICS & X11
# ==============================================================================
echo "🖥️  Installing X.org base, utilities, and GPU drivers..."
pkg install -y xorg xauth xinit xterm xrdb xsetroot xcursor-themes

case "$GPU_CHOICE" in
    1)
        if [ "$NVIDIA_VERSION" = "470" ]; then
            NV_PKG="nvidia-driver-470"
            NV_LINUX_PKG="linux-nvidia-libs-470"
        else
            NV_PKG="nvidia-driver"
            NV_LINUX_PKG="linux-nvidia-libs"
        fi
        
        echo "🟢 Installing NVIDIA proprietary driver ($NV_PKG)..."
        pkg install -y "$NV_PKG" "$NV_LINUX_PKG" libc6-shim nvidia-settings nvidia-xconfig
        
        add_kld_module "nvidia-modeset"
        add_line_if_missing 'hw.nvidiadrm.modeset="1"' /boot/loader.conf
        add_line_if_missing 'hw.nvidia.registry.EnableGpuFirmware="1"' /boot/loader.conf
        [ ! -f /etc/X11/xorg.conf ] && [ ! -f /usr/local/etc/X11/xorg.conf ] && nvidia-xconfig --silent
        ;;
    2)
        pkg install -y drm-kmod wayland xwayland
        add_kld_module "amdgpu"
        ;;
    3)
        pkg install -y drm-kmod wayland xwayland
        add_kld_module "i915kms"
        ;;
    4)
        pkg install -y xf86-video-scfb xf86-video-vmware xf86-video-vesa wayland xwayland
        ;;
esac

mkdir -p /usr/local/etc/X11/xorg.conf.d
cat > /usr/local/etc/X11/xorg.conf.d/20-keyboards.conf << EOF
Section "ServerFlags"
        Option "DontZap" "false"
EndSection
Section "InputClass"
        Identifier "All Keyboards"
        MatchIsKeyboard "yes"
        Option "XkbLayout" "${KBD_LAYOUT}"
EOF
[ -n "${KBD_VARIANT}" ] && echo "        Option \"XkbVariant\" \"${KBD_VARIANT}\"" >> /usr/local/etc/X11/xorg.conf.d/20-keyboards.conf
echo "        Option \"XkbOptions\" \"terminate:ctrl_alt_bksp\"" >> /usr/local/etc/X11/xorg.conf.d/20-keyboards.conf
echo "EndSection" >> /usr/local/etc/X11/xorg.conf.d/20-keyboards.conf

# ==============================================================================
# 9. DESKTOP ENVIRONMENT & SDDM
# ==============================================================================
STARTWM_EXEC=""
case "$DE_CHOICE" in
    1)
        pkg install -y sddm pavucontrol kate konsole ark dolphin Kvantum plasma6-plasma kf6-frameworks
        sysrc sddm_enable="YES"
        STARTWM_EXEC="exec startplasma-x11"
        ;;
    2)
        pkg install -y xfce sddm pavucontrol
        sysrc sddm_enable="YES"
        STARTWM_EXEC="exec startxfce4"
        ;;
    3)
        pkg install -y mate sddm pavucontrol
        sysrc sddm_enable="YES"
        STARTWM_EXEC="exec mate-session"
        ;;
esac

# SDDM Base Configuration (Forcing X11 DisplayServer)
if [ "$DE_CHOICE" -ne 4 ]; then
    echo "⌨️  Configuring SDDM keyboard layout & display server..."
    
    mkdir -p /usr/local/share/sddm/scripts
    cat > /usr/local/share/sddm/scripts/Xsetup << EOF
#!/bin/sh
if [ -x /usr/local/bin/setxkbmap ]; then
    if [ -n "${KBD_VARIANT}" ]; then
        /usr/local/bin/setxkbmap ${KBD_LAYOUT} ${KBD_VARIANT}
    else
        /usr/local/bin/setxkbmap ${KBD_LAYOUT}
    fi
fi
EOF
    chmod 555 /usr/local/share/sddm/scripts/Xsetup

    mkdir -p /var/db/sddm/.config
    cat > /var/db/sddm/.config/kxkbrc << EOF
[Layout]
DisplayNames=
LayoutList=${KBD_LAYOUT}
Use=true
VariantList=${KBD_VARIANT}
EOF
    chown -R sddm:sddm /var/db/sddm/.config 2>/dev/null || true
fi

# SDDM Theme Setup
if [ "$DE_CHOICE" -ne 4 ]; then
    THEME_NAME="breeze"
    if [ "$THEME_NASA" -eq 0 ]; then
        echo "🎨 Applying custom NASA SDDM theme..."
        rm -rf /tmp/fb14_assets
        git clone https://github.com/msartor99/FreeBSD14 /tmp/fb14_assets
        mkdir -p /usr/local/share/sddm/themes/nasa
        cp /usr/local/share/sddm/themes/maldives/* /usr/local/share/sddm/themes/nasa/ 2>/dev/null || true
        cp /tmp/fb14_assets/Main.qml /usr/local/share/sddm/themes/nasa/ 2>/dev/null || true
        cp /tmp/fb14_assets/metadata.desktop /usr/local/share/sddm/themes/nasa/ 2>/dev/null || true
        
        rm -f /usr/local/share/sddm/themes/nasa/background.*
        rm -f /usr/local/share/sddm/themes/nasa/preview.*
        
        cp /tmp/fb14_assets/nasa2560login.jpg /usr/local/share/sddm/themes/nasa/background.jpg 2>/dev/null || true
        cp /tmp/fb14_assets/nasa2560login.jpg /usr/local/share/sddm/themes/nasa/preview.png 2>/dev/null || true
        cp /tmp/fb14_assets/nasa2560login.jpg /usr/local/share/sddm/themes/nasa/preview.jpg 2>/dev/null || true
        
        if grep -q "^Preview=" /usr/local/share/sddm/themes/nasa/metadata.desktop 2>/dev/null; then
            sed -i '' 's/^Preview=.*/Preview=preview.png/' /usr/local/share/sddm/themes/nasa/metadata.desktop
        else
            echo "Preview=preview.png" >> /usr/local/share/sddm/themes/nasa/metadata.desktop
        fi

        if [ -f /usr/local/share/sddm/themes/nasa/theme.conf ]; then
            sed -i '' 's/^background=.*/background=background.jpg/' /usr/local/share/sddm/themes/nasa/theme.conf
        fi

        mkdir -p /boot/images
        cp -r /tmp/fb14_assets/freebsd-brand-rev.png /boot/images/ 2>/dev/null || true
        cp -r /tmp/fb14_assets/freebsd-logo-rev.png  /boot/images/ 2>/dev/null || true
        cp -r /tmp/fb14_assets/nasa1920.png /boot/images/splash.png 2>/dev/null || true
        sysrc -f /boot/loader.conf splash="/boot/images/splash.png"
        
        fetch -o /tmp/fb14_assets/nasa_4k_wallpaper.jpg https://raw.githubusercontent.com/msartor99/FreeBSD14/ffdccbb160df14397836ce9b3b361c9ab87f97a9/wp8860763-nasa-4k-wallpapers.jpg 2>/dev/null || true
        
        if [ -f /tmp/fb14_assets/nasa_4k_wallpaper.jpg ]; then
            if [ "$DE_CHOICE" -eq 1 ]; then
                mkdir -p /usr/local/share/wallpapers/NASA_4K/contents/images
                cp /tmp/fb14_assets/nasa_4k_wallpaper.jpg /usr/local/share/wallpapers/NASA_4K/contents/images/3840x2160.jpg
                cat > /usr/local/share/wallpapers/NASA_4K/metadata.desktop << 'EOF_KDE'
[Desktop Entry]
Name=NASA 4K
X-KDE-PluginInfo-Name=NASA_4K
EOF_KDE
                mkdir -p /usr/share/skel/dot.config
                printf "[Wallpaper][org.kde.image][General]\nImage=/usr/local/share/wallpapers/NASA_4K\n" > /usr/share/skel/dot.config/kscreenlockerrc
                if [ -d "/home/$MAIN_USER" ]; then
                    mkdir -p "/home/$MAIN_USER/.config"
                    printf "[Wallpaper][org.kde.image][General]\nImage=/usr/local/share/wallpapers/NASA_4K\n" > "/home/$MAIN_USER/.config/kscreenlockerrc"
                    chown -R "$MAIN_USER:wheel" "/home/$MAIN_USER/.config"
                fi
            fi
        fi
        THEME_NAME="nasa"
    fi

    # Write final SDDM Configuration forcing X11 Mode
    cat > /usr/local/etc/sddm.conf << EOF
[General]
DisplayServer=x11

[Theme]
Current=${THEME_NAME}
EOF
fi

# ==============================================================================
# 10. METAPACKAGES (Internet, Media, Vbox, etc.)
# ==============================================================================
if echo "$APP_CHOICES" | grep -q "INTERNET"; then
    pkg install -y firefox thunderbird cantarell-fonts droid-fonts-ttf noto-basic nerd-fonts
fi

if echo "$APP_CHOICES" | grep -q "MEDIA"; then
    pkg install -y pulseaudio pipewire wireplumber vlc ffmpeg multimedia/mpv kdenlive webcamd v4l-utils
    sysrc webcamd_enable="YES"
    [ "$GPU_CHOICE" -eq 1 ] && add_line_if_missing "hw.snd.default_unit=1" /etc/sysctl.conf
fi

if echo "$APP_CHOICES" | grep -q "VBOX"; then
    pkg install -y ${VBOX_PKG}
    sysrc -f /boot/loader.conf vboxdrv_load="YES"
    sysrc vboxnet_enable="YES"
    pw groupmod vboxusers -m root 2>/dev/null || true
    pw groupmod vboxusers -m "$MAIN_USER" 2>/dev/null || true
    add_line_if_missing "own vboxnetctl root:vboxusers" /etc/devfs.conf
    add_line_if_missing "perm vboxnetctl 0660" /etc/devfs.conf
fi

if echo "$APP_CHOICES" | grep -q "XRDP"; then
    pkg install -y xrdp xorgxrdp
    sysrc xrdp_enable="YES"
    sysrc xrdp_sesman_enable="YES"
    mkdir -p /usr/local/etc/xrdp
    cat > /usr/local/etc/xrdp/startwm.sh << EOF
#!/bin/sh
export LANG=${SYS_LANG}
export LC_ALL=${SYS_LANG}
$STARTWM_EXEC
EOF
    chmod 555 /usr/local/etc/xrdp/startwm.sh
fi

if echo "$APP_CHOICES" | grep -q "SAMBA"; then
    pkg install -y ${SAMBA_PKG}
    smbpasswd -a "$MAIN_USER" 2>/dev/null || true
    mkdir -p /home/share
    chmod 777 /home/share
    cat > /usr/local/etc/smb4.conf << EOF
[global]
    unix charset = UTF-8
    workgroup = HOMELAB
    server string = FreeBSD
    map to guest = bad user
[Share]
    path = /home/share
    writable = yes
    valid users = ${MAIN_USER}
    guest ok = no
    force create mode = 0775
EOF
    sysrc samba_server_enable="YES"
fi

# ==============================================================================
# 11. CLEANUP & FINISH
# ==============================================================================
rm -f "$MENU_OUT"
echo "=========================================================================="
echo "✅ Installation complete! A reboot is recommended."
echo "=========================================================================="
