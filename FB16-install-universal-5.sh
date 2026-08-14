#!/bin/sh

# --- CONFIGURATION AND VERIFICATION ---
TITLE="FreeBSD Post-Installation (Idempotent)"
BACKTITLE="Workstation Configuration"

if ! command -v bsddialog >/dev/null 2>&1; then
    echo "Installing bsddialog..."
    pkg update && pkg install -y bsddialog
fi

# Utility function to add a line to a file if it doesn't already exist
add_line_if_missing() {
    # $1: line to add, $2: file
    grep -qF -- "$1" "$2" 2>/dev/null || echo "$1" >> "$2"
}

# Utility function to safely add kernel modules to kld_list
add_kld_module() {
    MOD="$1"
    sysrc -n kld_list | grep -qw "$MOD" || sysrc kld_list+="$MOD"
}

# --- DISCLAIMER AND CREDITS ---
show_disclaimer() {
    local msg="DISCLAIMER OF LIABILITY\n\n\
This script deeply modifies your FreeBSD system configuration. \
It is provided 'as is', without any express or implied warranty. \
By using it, you agree that the author cannot be held responsible \
for any data loss, system breakage, or other damage.\n\n\
Do you accept these conditions to continue?"

    if ! bsddialog --backtitle "$BACKTITLE" --title "Warning" --yesno "$msg" 15 75; then
        clear
        echo "Installation cancelled by the user. No changes have been made."
        exit 1
    fi
}

# --- VERSION SELECTION ---
choose_version() {
    FREEBSD_VER=$(bsddialog --backtitle "$BACKTITLE" --title "FreeBSD Target Version" \
        --menu "Select your installed FreeBSD version branch to adapt the installations:" 12 75 2 \
        "15" "FreeBSD 15.1-RELEASE (Stable branch)" \
        "16" "FreeBSD 16.0-CURRENT (Development branch)" 3>&1 1>&2 2>&3)
    
    if [ -z "$FREEBSD_VER" ]; then
        clear
        echo "No version selected. Exiting."
        exit 1
    fi
}

# --- FUNCTIONS ---

base_config() {
    bsddialog --infobox "Updating system and applying base configuration..." 5 50
    pkg update -y && pkg install -y sudo
    
    sed -i '' 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    add_line_if_missing "PermitRootLogin yes" /etc/ssh/sshd_config
    service sshd restart

    sysrc -f /boot/loader.conf boot_mute=YES splash_changer_enable=YES autoboot_delay=3
    
    if ! grep -qF 'run_rc_script ${_rc_elem} ${_boot} > /dev/null' /etc/rc; then
        sed -i '' 's/run_rc_script ${_rc_elem} ${_boot}/run_rc_script ${_rc_elem} ${_boot} > \/dev\/null/g' /etc/rc
    fi
    sysrc rc_startmsgs=NO
    
    add_line_if_missing "kern.sched.preempt_thresh=224" /etc/sysctl.conf
    add_line_if_missing "kern.ipc.shm_allow_removed=1" /etc/sysctl.conf
    sysrc -f /boot/loader.conf tmpfs_load=YES aio_load=YES
    
    sysctl net.local.stream.recvspace=65536 net.local.stream.sendspace=65536
    
    pkg install -y doas unzip libzip wget git htop neofetch python3 bashtop ImageMagick7 smartmontools ca_root_nss
    certctl rehash

    sysrc smartd_enable=YES
    [ ! -f /usr/local/etc/smartd.conf ] && cp /usr/local/etc/smartd.conf.sample /usr/local/etc/smartd.conf
    service smartd restart 2>/dev/null || service smartd start

    # --- Localization (French/Swiss defaults) ---
    if ! grep -q "french|French Users Accounts" /etc/login.conf; then
        cat >> /etc/login.conf <<EOF

french|French Users Accounts:\
    :charset=UTF-8:\
    :lang=fr_FR.UTF-8:\
    :lc_all=fr_FR:\
    :lc_collate=fr_FR:\
    :lc_ctype=fr_FR:\
    :lc_messages=fr_FR:\
    :tc=default:
EOF
        cap_mkdb /etc/login.conf
    fi
    echo 'defaultclass=french' > /etc/adduser.conf
    
    USER_NAME=$(bsddialog --inputbox "Local Configuration:\nEnter main user name (default: administrateur):" 9 50 "administrateur" 3>&1 1>&2 2>&3)
    if [ -n "$USER_NAME" ]; then
        export USER_NAME
        pw usermod "$USER_NAME" -G wheel,operator,video -L french 2>/dev/null || pw useradd "$USER_NAME" -m -G wheel,operator,video -s /bin/sh -c "System Administrator" -L french
    fi
    pw usermod root -L french
}

cpu_config() {
    CHOICE=$(bsddialog --menu "Select CPU Type:" 12 50 2 "Intel" "Coretemp/Ucode" "AMD" "Amdtemp/Ucode" 3>&1 1>&2 2>&3)
    case $CHOICE in
        Intel) 
            pkg install -y cpu-microcode sensors
            sysrc -f /boot/loader.conf coretemp_load="YES"
            sysrc -f /boot/loader.conf cpu_microcode_name="/boot/firmware/intel-ucode.bin" 
            ;;
        AMD) 
            pkg install -y sensors cpu-microcode
            sysrc -f /boot/loader.conf amdtemp_load="YES" 
            sysrc -f /boot/loader.conf cpu_microcode_load="YES"
            sysrc -f /boot/loader.conf cpu_microcode_name="/boot/firmware/amd-ucode.bin" 
            ;;
    esac
}

hardware_config() {
    bsddialog --infobox "Installing Hardware Base, Xorg and SDDM..." 5 60
    
    if [ "$FREEBSD_VER" = "16" ]; then
        pkg install -y xorg dbus avahi seatd sddm xf86-input-libinput
        add_kld_module "evdev"
    else
        pkg install -y xorg dbus avahi seatd sddm
    fi
    
    # Audio - PulseAudio uniquement (pas de PipeWire pour éviter les conflits)
    pkg install -y pulseaudio freedesktop-sound-theme
    
    pkg install -y cups gutenprint cups-filters hplip system-config-printer
    pkg install -y fusefs-ntfs fusefs-hfsfuse signal-cli
    
    sysrc sound_load="YES" snd_hda_load="YES"
    
    # Fix Son: Canal DisplayPort par défaut au niveau du noyau
    add_line_if_missing "hw.snd.default_unit=1" /etc/sysctl.conf
    
    # Fix Son: Création d'un script de démarrage KDE différé pour attacher PulseAudio au dsp1
    mkdir -p /usr/local/etc/xdg/autostart
    cat > /usr/local/bin/init-kde-audio.sh <<'EOF'
#!/bin/sh
sleep 4
pulseaudio -k 2>/dev/null
pulseaudio --start
pactl load-module module-oss device=/dev/dsp1
EOF
    chmod +x /usr/local/bin/init-kde-audio.sh

    cat > /usr/local/etc/xdg/autostart/init-kde-audio.desktop <<EOF
[Desktop Entry]
Exec=/usr/local/bin/init-kde-audio.sh
Name=Initialize KDE Audio
Type=Application
OnlyShowIn=KDE;
EOF
    
    sysrc dbus_enable=YES avahi_enable=YES seatd_enable=YES sddm_enable=YES sddm_lang="fr_CH.UTF-8"
    sysrc cupsd_enable=YES devfs_system_ruleset=localrules
    
    add_kld_module "fusefs"
    add_kld_module "ext2fs"
    
    add_line_if_missing "vfs.usermount=1" /etc/sysctl.conf
    add_line_if_missing "proc /proc procfs rw 0 0" /etc/fstab
    add_line_if_missing "fdesc /dev/fd fdescfs rw 0 0" /etc/fstab

    # --- Devfs Rules Adaptation (incluant dsp* et mixer* en 0666) ---
    if [ "$FREEBSD_VER" = "16" ]; then
        cat >/etc/devfs.rules <<EOF
[localrules=5]
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
add path 'input/*' mode 0660 group operator
add path 'unlpt*' mode 0660 group cups
add path 'lpt*' mode 0660 group cups
add path 'dri/*' mode 0666
add path 'dri/card*' mode 0666
add path 'dri/renderD*' mode 0666
add path 'video*' mode 0660 group video
add path 'nvidia*' mode 0666
add path 'nvidia-modeset*' mode 0666
add path 'nvidia-uvm*' mode 0666
add path 'dsp*' mode 0666
add path 'mixer*' mode 0666
EOF
    else
        if [ ! -f /etc/devfs.rules ] || ! grep -q "localrules" /etc/devfs.rules; then
            cat >>/etc/devfs.rules <<EOF
[localrules=5]
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
add path 'dsp*' mode 0666
add path 'mixer*' mode 0666
EOF
        else
            add_line_if_missing "add path 'dsp*' mode 0666" /etc/devfs.rules
            add_line_if_missing "add path 'mixer*' mode 0666" /etc/devfs.rules
        fi
    fi
    service devfs restart 2>/dev/null || true

    mkdir -p /usr/local/etc/X11/xorg.conf.d/

    # --- UNLOCK CTRL+ALT+BACKSPACE ---
    cat >/usr/local/etc/X11/xorg.conf.d/10-serverflags.conf <<EOF
Section "ServerFlags"
    Option "DontZap" "false"
EndSection
EOF

    # Swiss French Keyboard Configuration
    cat >/usr/local/etc/X11/xorg.conf.d/20-keyboards.conf <<EOF
Section "InputClass"
    Identifier "All Keyboards"
    MatchIsKeyboard "yes"
    Option "XkbLayout" "ch"
    Option "XkbVariant" "fr"
    Option "XkbOptions" "terminate:ctrl_alt_bksp"
EndSection
EOF

    if [ "$FREEBSD_VER" = "16" ]; then
        mkdir -p /usr/local/share/sddm/scripts
        cat > /usr/local/share/sddm/scripts/Xsetup <<EOF
#!/bin/sh
vidcontrol -s 9 < /dev/ttyv0 2>/dev/null || true
setxkbmap ch fr
EOF
        chmod 555 /usr/local/share/sddm/scripts/Xsetup

        cat > /usr/local/etc/sddm.conf <<EOF
[General]
DisplayServer=x11
GreeterEnvironment=QT_QUICK_BACKEND=software,LANG=fr_CH.UTF-8,LC_ALL=fr_CH.UTF-8

[X11]
MinimumVT=7
EOF
    else
        if [ -f /usr/local/share/sddm/scripts/Xsetup ]; then
            add_line_if_missing "setxkbmap ch fr" /usr/local/share/sddm/scripts/Xsetup
        fi
    fi
}

nvidia_config() {
    GPU_INFO=$(pciconf -lv | grep -i -B 1 -A 2 "vendor.*NVIDIA" | grep "device.*=" | cut -d "'" -f 2)
    [ -z "$GPU_INFO" ] && GPU_INFO="Unknown or undetected Nvidia GPU"

    REC_DRIVER="nvidia-driver"
    
    if echo "$GPU_INFO" | grep -iqE "Quadro P|GTX 10|Pascal"; then
        REC_DRIVER="nvidia-driver-580"
    elif echo "$GPU_INFO" | grep -iqE "Quadro M|GTX 9|GTX 750|Maxwell"; then
        REC_DRIVER="nvidia-driver-470"
    elif echo "$GPU_INFO" | grep -iqE "Quadro K|GTX 7|GTX 6|Kepler"; then
        REC_DRIVER="nvidia-driver-390"
    fi

    CHOICE=$(bsddialog --title "Nvidia Configuration" --menu "Detected GPU: $GPU_INFO\n\nRecommended Driver: $REC_DRIVER\n\nChoose your driver version:" 17 85 5 \
        "nvidia-driver" "Latest (RTX, GTX 16+, Quadro RTX...)" \
        "nvidia-driver-580" "Legacy 580 (Pascal: Quadro P, GTX 10xx)" \
        "nvidia-driver-470" "Legacy 470 (Maxwell: Quadro M, GTX 9xx)" \
        "nvidia-driver-390" "Legacy 390 (Kepler: Quadro K, GTX 7xx)" \
        "Back" "Do not install anything" 3>&1 1>&2 2>&3)

    case $CHOICE in
        "nvidia-driver"|"nvidia-driver-580"|"nvidia-driver-470"|"nvidia-driver-390")
            DRIVER_PKG="$CHOICE"
            ;;
        *) return ;;
    esac

    if [ "$DRIVER_PKG" = "nvidia-driver" ]; then
        LINUX_LIBS="linux-nvidia-libs"
    else
        SUFFIX=$(echo "$DRIVER_PKG" | cut -d'-' -f3)
        LINUX_LIBS="linux-nvidia-libs-${SUFFIX}"
    fi

    bsddialog --infobox "Preparing Linux compatibility layer..." 5 60
    
    clean_kld=$(sysrc -n kld_list | sed -E 's/\b(linux64|linux)\b//g' | xargs)
    sysrc kld_list="linux linux64 $clean_kld"
    sysrc linux_enable="YES"
    
    kldload -n linux 2>/dev/null
    kldload -n linux64 2>/dev/null
    
    pkg install -y linux-rl9
    service linux restart 2>/dev/null || service linux start

    bsddialog --infobox "Installing $DRIVER_PKG and $LINUX_LIBS..." 5 60
    
    if [ "$FREEBSD_VER" = "16" ]; then
        pkg install -y "$DRIVER_PKG" "$LINUX_LIBS" libc6-shim nvidia-settings nvidia-drm-kmod
        add_kld_module "nvidia-drm"
        add_line_if_missing "hw.nvidiadrm.modeset=\"1\"" /boot/loader.conf
        add_line_if_missing "nvidia-drm.modeset=\"1\"" /boot/loader.conf
        pw groupmod video -m sddm 2>/dev/null || true
    else
        pkg install -y "$DRIVER_PKG" "$LINUX_LIBS" libc6-shim nvidia-settings
        add_line_if_missing "hw.nvidiadrm.modeset=\"1\"" /boot/loader.conf
    fi
    
    add_kld_module "nvidia-modeset"
    sysrc nvidia_modeset_enable="YES"
    add_line_if_missing "hw.nvidia.registry.EnableGpuFirmware=\"1\"" /boot/loader.conf
    
    mkdir -p /usr/local/etc/X11/xorg.conf.d/
    cat >/usr/local/etc/X11/xorg.conf.d/driver-nvidia.conf <<EOF
Section "Device"
    Identifier     "NVIDIA Card"
    Driver         "nvidia"
    VendorName     "NVIDIA Corporation"
    Option         "NoLogo" "true"
EndSection
EOF

    bsddialog --msgbox "Nvidia drivers configured successfully!" 6 60
}

amd_config() {
    GPU_INFO=$(pciconf -lv | grep -i -B 1 -A 2 "vendor.*AMD\|ATI" | grep "device.*=" | cut -d "'" -f 2 | head -n 1)
    [ -z "$GPU_INFO" ] && GPU_INFO="Unknown or undetected AMD GPU"

    REC_DRIVER="amdgpu" 
    
    if echo "$GPU_INFO" | grep -iqE "Radeon HD|Radeon R[579]|FirePro|Mobility Radeon"; then
        REC_DRIVER="radeonkms"
    fi

    CHOICE=$(bsddialog --title "AMD Configuration" --menu "Detected GPU: $GPU_INFO\n\nRecommended Driver: $REC_DRIVER\n\nChoose your driver:" 16 85 3 \
        "amdgpu" "Modern cards (RX 400+, Ryzen APU, Vega, Navi)" \
        "radeonkms" "Legacy cards (Radeon HD, R5/R7/R9 pre-GCN3)" \
        "Back" "Do not install anything" 3>&1 1>&2 2>&3)

    case $CHOICE in
        "amdgpu"|"radeonkms")
            DRIVER_PKG="$CHOICE"
            ;;
        *) return ;;
    esac

    bsddialog --infobox "Installing DRM packages..." 5 50
    pkg install -y drm-kmod
    
    add_kld_module "$DRIVER_PKG"
    [ "$FREEBSD_VER" = "16" ] && pw groupmod video -m sddm 2>/dev/null || true
    
    bsddialog --msgbox "AMD Graphics Driver ($DRIVER_PKG) configured successfully!" 6 60
}

plasma_config() {
    bsddialog --infobox "Installing Plasma 6 (KDE)..." 5 50
    pkg install -y -g "plasma6-*" "kf6-*"
    pkg install -y plasma6-discover kf6-knewstuff kf6-purpose qt6-svg qt6-imageformats
    pkg install -y pavucontrol kate konsole ark remmina dolphin Kvantum
}

mate_config() {
    bsddialog --infobox "Installing MATE Desktop..." 5 50
    pkg install -y mate mate-desktop octopkg
}

cinnamon_config() {
    bsddialog --infobox "Installing Cinnamon Desktop..." 5 50
    pkg install -y cinnamon
}

samba_config() {
    pkg install -y samba419
    mkdir -p /home/share && chmod 777 /home/share
    if [ ! -f /usr/local/etc/smb4.conf ]; then
        cat > /usr/local/etc/smb4.conf <<EOF
[global]
    workgroup = HOMELAB
    map to guest = bad user
[Share]
    path = /home/share
    writable = yes
    guest ok = yes
EOF
    fi
    sysrc samba_server_enable="YES"
    service samba_server restart 2>/dev/null || service samba_server start
}

xrdp_config() {
    pkg install -y xrdp xorgxrdp
    sysrc xrdp_enable="YES" xrdp_sesman_enable="YES"
    [ ! -f /usr/local/etc/xrdp/startwm.sh.backup ] && mv /usr/local/etc/xrdp/startwm.sh /usr/local/etc/xrdp/startwm.sh.backup
    echo 'export LANG=fr_FR.UTF-8' > /usr/local/etc/xrdp/startwm.sh
    echo 'exec startplasma-x11' >> /usr/local/etc/xrdp/startwm.sh
    chmod 555 /usr/local/etc/xrdp/startwm.sh
}

vbox_config() {
    if [ "$FREEBSD_VER" = "16" ]; then
        pkg install -y virtualbox-ose
    else
        pkg install -y virtualbox-ose-72
    fi
    
    sysrc -f /boot/loader.conf vboxdrv_load="YES" vboxnet_load="YES"
    sysrc vboxnet_enable="YES"
    pw groupmod vboxusers -m root
    [ -n "$USER_NAME" ] && pw groupmod vboxusers -m "$USER_NAME"
    add_line_if_missing 'own     vboxnetctl root:vboxusers' /etc/devfs.conf
    add_line_if_missing 'perm    vboxnetctl 0660' /etc/devfs.conf
}

apps_config() {
    bsddialog --infobox "Installing applications and system fonts..." 5 50
    if [ "$FREEBSD_VER" = "16" ]; then
        pkg install -y firefox thunderbird vlc ffmpeg kdenlive webcamd win98se-icon-theme ImageMagick7
    else
        pkg install -y firefox chromium thunderbird vlc ffmpeg kdenlive webcamd win98se-icon-theme ImageMagick7
    fi
    pkg install -y libreoffice fr-libreoffice
    pkg install -y cantarell-fonts droid-fonts-ttf inconsolata-ttf noto-basic noto-emoji roboto-fonts-ttf ubuntu-font webfonts terminus-font terminus-ttf
    sysrc webcamd_enable=YES
}

switch_latest() {
    sed -i '' 's/quarterly/latest/g' /etc/pkg/FreeBSD.conf
    pkg update -f && pkg upgrade -y
}

vnc_config() {
    if [ -z "$USER_NAME" ]; then
        VNC_USER=$(bsddialog --title "X11VNC Configuration" --inputbox "No user configured. Enter the system user for VNC access:" 8 65 "administrateur" 3>&1 1>&2 2>&3)
        [ -z "$VNC_USER" ] && return
    else
        VNC_USER="$USER_NAME"
    fi
    
    VNC_PASS=$(bsddialog --title "X11VNC Configuration" --insecure --passwordbox "Define a secure VNC access password for user '$VNC_USER':" 8 65 3>&1 1>&2 2>&3)
    [ -z "$VNC_PASS" ] && return

    bsddialog --infobox "Installing and configuring x11vnc..." 5 50
    pkg install -y x11vnc

    mkdir -p "/home/$VNC_USER/.vnc"
    x11vnc -storepasswd "$VNC_PASS" "/home/$VNC_USER/.vnc/passwd" > /dev/null 2>&1
    
    chown -R "$VNC_USER:$VNC_USER" "/home/$VNC_USER/.vnc"
    chmod 600 "/home/$VNC_USER/.vnc/passwd"

    cat > /usr/local/etc/rc.d/x11vnc <<EOF
#!/bin/sh
#
# PROVIDE: x11vnc
# REQUIRE: sddm
# KEYWORD: shutdown

. /etc/rc.subr

name="x11vnc"
rcvar="x11vnc_enable"

load_rc_config \$name

: \${x11vnc_enable:="NO"}

export PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"

procname="/usr/local/bin/x11vnc"
command="/usr/sbin/daemon"
pidfile="/var/run/\${name}.pid"

x11vnc_precmd() {
    XAUTH=\$(ps -wwaux | grep -E '/Xorg' | grep -v grep | sed -n 's/.*-auth \([^ ]*\).*/\1/p' | head -n 1)
    
    if [ -z "\$XAUTH" ]; then
        XAUTH=\$(ls /var/run/sddm/xauth_* 2>/dev/null | head -n 1)
    fi
    
    if [ -n "\$XAUTH" ]; then
        command_args="-f -p \${pidfile} \${procname} -display :0 -rfbport 5900 -rfbauth /home/$VNC_USER/.vnc/passwd -auth \$XAUTH -forever -shared -loop"
    else
        command_args="-f -p \${pidfile} \${procname} -display :0 -rfbport 5900 -rfbauth /home/$VNC_USER/.vnc/passwd -auth guess -forever -shared -loop"
    fi
}

start_precmd="x11vnc_precmd"

run_rc_command "\$1"
EOF

    chmod +x /usr/local/etc/rc.d/x11vnc
    sysrc x11vnc_enable="YES"
    
    service x11vnc restart 2>/dev/null || service x11vnc start 2>/dev/null
    
    bsddialog --msgbox "X11VNC Server successfully installed and configured for '$VNC_USER' on port 5900!\n\nThe service is set to start in the background immediately after SDDM." 9 70
}

iphone_config() {
    bsddialog --infobox "Installing iPhone connectivity tools (usbmuxd, libimobiledevice, ifuse)..." 5 75
    
    pkg install -y usbmuxd libimobiledevice ifuse

    sysrc usbmuxd_enable="YES"
    service usbmuxd restart 2>/dev/null || service usbmuxd start

    add_kld_module "fusefs"
    kldload -n fusefs 2>/dev/null

    add_line_if_missing "vfs.usermount=1" /etc/sysctl.conf
    sysctl vfs.usermount=1 2>/dev/null

    IPHONE_USER="${USER_NAME:-administrateur}"

    if [ -d "/home/$IPHONE_USER" ]; then
        mkdir -p "/home/$IPHONE_USER/Desktop/iPhone_Photos"
        mkdir -p "/home/$IPHONE_USER/Desktop/iPhone_Music_VLC"
        chown -R "$IPHONE_USER:$IPHONE_USER" "/home/$IPHONE_USER/Desktop/iPhone_Photos"
        chown -R "$IPHONE_USER:$IPHONE_USER" "/home/$IPHONE_USER/Desktop/iPhone_Music_VLC"
    fi

    cat > /usr/local/bin/iphone-sync <<EOF
#!/bin/sh
USER_HOME="/home/$IPHONE_USER"
PHOTO_DIR="\$USER_HOME/Desktop/iPhone_Photos"
VLC_DIR="\$USER_HOME/Desktop/iPhone_Music_VLC"

case "\$1" in
    mount)
        echo "Attempting to mount iPhone..."
        umount "\$PHOTO_DIR" 2>/dev/null
        umount "\$VLC_DIR" 2>/dev/null
        ifuse "\$PHOTO_DIR" && echo "-> Photos mounted to \$PHOTO_DIR"
        ifuse --documents org.videolan.vlc-ios "\$VLC_DIR" 2>/dev/null && echo "-> VLC App detected and mounted to \$VLC_DIR"
        echo "\n[Success] Don't forget to tap 'Trust' on your iPhone screen!"
        ;;
    unmount|umount)
        echo "Safely unmounting iPhone..."
        umount "\$PHOTO_DIR" 2>/dev/null
        umount "\$VLC_DIR" 2>/dev/null
        echo "[Success] You can now safely disconnect your iPhone."
        ;;
    list|apps)
        ifuse --list-apps
        ;;
    *)
        echo "Usage: iphone-sync [mount | umount | apps]"
        ;;
esac
EOF

    chmod +x /usr/local/bin/iphone-sync

    local tuto_msg="iPhone configuration completed successfully! 🍏\n\n\
Run 'iphone-sync mount' in your terminal to mount the iPhone to your Desktop.\n\
Ensure VLC is installed on your iOS device for media sync."
    bsddialog --title "iPhone Sync" --msgbox "$tuto_msg" 10 70
}

# --- SCRIPT START ---

show_disclaimer
choose_version

# --- MAIN MENU ---
while true; do
    MAIN_CHOICE=$(bsddialog --backtitle "$BACKTITLE" --title "$TITLE" \
        --menu "Post-Installation Menu [Target: FreeBSD $FREEBSD_VER]:" 24 85 15 \
        "1" "Base Config & Locales (SSH, Boot, Linux, User)" \
        "2" "CPU Management (Intel/AMD)" \
        "3" "Hardware Base (Audio, Xorg, CUPS)" \
        "4" "GPU: NVIDIA (Auto-Detect)" \
        "5" "GPU: AMD / Radeon (Auto-Detect)" \
        "6" "Desktop (Plasma 6)" \
        "7" "Desktop (MATE)" \
        "8" "Desktop (Cinnamon)" \
        "9" "Samba Server" \
        "10" "XRDP Remote Desktop" \
        "11" "VirtualBox" \
        "12" "Applications & Fonts" \
        "13" "Upgrade to LATEST Branch" \
        "14" "X11VNC Server (Fast Connection)" \
        "15" "iPhone Connect Support (VLC & Photos)" \
        "Q" "Quit" 3>&1 1>&2 2>&3)

    case $MAIN_CHOICE in
        1) base_config ;;
        2) cpu_config ;;
        3) hardware_config ;;
        4) nvidia_config ;;
        5) amd_config ;;
        6) plasma_config ;;
        7) mate_config ;;
        8) cinnamon_config ;;
        9) samba_config ;;
        10) xrdp_config ;;
        11) vbox_config ;;
        12) apps_config ;;
        13) switch_latest ;;
        14) vnc_config ;;
        15) iphone_config ;;
        Q|q|*) break ;;
    esac
done
clear
echo "Script completed. A system reboot is highly recommended to apply all changes."