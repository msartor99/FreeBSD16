#!/bin/sh
# ==============================================================================
# Script Name : freebsd16-workstation-setup-v1.0.sh
# Description : Idempotent FreeBSD 16 Workstation Post-Install Configuration
#               Using native bsddialog checklist TUI with smart submenus
# Author      : msartor99 (https://github.com/msartor99)
# License     : BSD-2-Clause
# Target OS   : FreeBSD 16.0-CURRENT / 16-RELEASE (Base System POSIX /bin/sh)
# Version     : 1.0
# ==============================================================================

set -u

SCRIPT_VERSION="1.0"
SCRIPT_NAME="freebsd16-workstation-setup-v${SCRIPT_VERSION}.sh"

# Log files (/tmp for live inspection + /var/log to survive reboot)
LOG_FILE="/tmp/freebsd16-workstation-setup-v${SCRIPT_VERSION}.log"
PERSISTENT_LOG="/var/log/freebsd16-workstation-setup-v${SCRIPT_VERSION}.log"
ERROR_COUNT=0

# Support --version / -v CLI flag
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    printf "%s version %s\n" "$SCRIPT_NAME" "$SCRIPT_VERSION"
    exit 0
fi

# Target user is intentionally empty at startup and requested after disclaimer
TARGET_USER=""
SAMBA_SUBNET="192.168.22.0/24"
ASSETS_REPO="https://github.com/msartor99/FreeBSD14"
ASSETS_DIR="/tmp/fb14_assets"
BACKTITLE="FreeBSD 16 Workstation Setup v${SCRIPT_VERSION} - github.com/msartor99"

# Submenu state variables
CPU_CHOICE=""
GPU_CHOICE=""
NVIDIA_4K_CHOICE="NO"
SPLASH_CHOICE=""
DE_CHOICE=""
PKG_CHOICE=""

# ==============================================================================
# LOGGING & EXECUTION HELPERS
# ==============================================================================

init_log() {
    cat > "$LOG_FILE" <<EOF
==============================================================================
FreeBSD 16 Workstation Setup Log - Version ${SCRIPT_VERSION}
Started at : $(date '+%Y-%m-%d %H:%M:%S')
Hostname   : $(hostname)
Kernel     : $(uname -sr)
==============================================================================
EOF
    chmod 0644 "$LOG_FILE"
    cp -f "$LOG_FILE" "$PERSISTENT_LOG" 2>/dev/null || true
}

sync_log() {
    cp -f "$LOG_FILE" "$PERSISTENT_LOG" 2>/dev/null || true
}

log_raw() {
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE"
    sync_log
}

msg_info() {
    printf "\033[1;34m[INFO]\033[0m %s\n" "$*"
    log_raw "[INFO] $*"
}

msg_ok() {
    printf "\033[1;32m[OK]\033[0m %s\n" "$*"
    log_raw "[OK] $*"
}

msg_warn() {
    printf "\033[1;33m[WARN]\033[0m %s\n" "$*"
    log_raw "[WARN] $*"
}

msg_err() {
    printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2
    log_raw "[ERROR] $*"
    ERROR_COUNT=$((ERROR_COUNT + 1))
}

run_cmd() {
    _step_desc="$1"
    shift
    log_raw "CMD (${_step_desc}): $*"
    "$@" >> "$LOG_FILE" 2>&1
    _rc=$?
    if [ $_rc -eq 0 ]; then
        msg_ok "${_step_desc}"
    else
        msg_err "${_step_desc} FAILED (exit code ${_rc}) -> Command: $*"
    fi
    sync_log
    return $_rc
}

pkg_install_logged() {
    _step_name="$1"
    shift
    msg_info "[${_step_name}] Installing packages: $*"
    log_raw "[${_step_name}] CMD: pkg install -y $*"
    if pkg install -y "$@" >> "$LOG_FILE" 2>&1; then
        msg_ok "[${_step_name}] Batch package install succeeded ($*)"
        sync_log
        return 0
    fi

    msg_warn "[${_step_name}] Batch install had unavailable packages, installing available ones individually..."
    for _pkg in "$@"; do
        if pkg rquery "%n" "$_pkg" >/dev/null 2>&1 || pkg info -e "$_pkg" >/dev/null 2>&1; then
            log_raw "[${_step_name}] Installing verified package: pkg install -y ${_pkg}"
            if pkg install -y "$_pkg" >> "$LOG_FILE" 2>&1; then
                msg_ok "[${_step_name}] Installed package: ${_pkg}"
            else
                msg_err "[${_step_name}] Failed to install package: ${_pkg}"
            fi
        else
            msg_warn "[${_step_name}] Skipping optional package not present in FreeBSD 16 repo: ${_pkg}"
        fi
    done
    sync_log
    return 0
}

pkg_install_glob_logged() {
    _step_name="$1"
    _glob="$2"
    msg_info "[${_step_name}] Installing package glob: ${_glob}"
    log_raw "[${_step_name}] CMD: pkg install -y -g ${_glob}"
    if pkg install -y -g "$_glob" >> "$LOG_FILE" 2>&1; then
        msg_ok "[${_step_name}] Glob package install succeeded: ${_glob}"
    else
        msg_err "[${_step_name}] Glob package install failed: ${_glob}"
    fi
    sync_log
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "\033[1;31m[ERROR]\033[0m This script must be run as root.\n" >&2
        exit 1
    fi
}

check_bsddialog() {
    if ! command -v bsddialog >/dev/null 2>&1; then
        printf "\033[1;31m[ERROR]\033[0m 'bsddialog' utility was not found in the base system.\n" >&2
        exit 1
    fi
}

show_disclaimer() {
    bsddialog --backtitle "$BACKTITLE" \
        --title " WARNING / DISCLAIMER (v${SCRIPT_VERSION}) " \
        --default-no \
        --yes-label "Yes, I Accept" \
        --no-label "No, Exit" \
        --yesno "WARNING: This script (${SCRIPT_NAME}) will modify critical system configuration files on this FreeBSD workstation (/boot/loader.conf, /etc/rc.conf, /etc/sysctl.conf, /etc/fstab, /etc/devfs.rules, X11, SDDM, and packages).\n\nAlthough designed to be idempotent, running system-wide automation carries inherent risks. Ensure you have a backup or ZFS snapshot before proceeding.\n\nExecution logs will be written to:\n  - ${LOG_FILE}\n  - ${PERSISTENT_LOG}\n\nDo you accept full responsibility and wish to continue?" 19 78

    if [ $? -ne 0 ]; then
        clear
        msg_warn "Disclaimer declined by operator. Exiting without changes."
        exit 0
    fi
}

ask_target_user() {
    while true; do
        USER_INPUT=$(bsddialog --backtitle "$BACKTITLE" \
            --title " Target User Configuration " \
            --ok-label "Confirm" \
            --cancel-label "Exit" \
            --inputbox "Please enter the target username to configure (sudo, groups, locale, VirtualBox, audio, D-Bus, etc.):" 10 70 "" 3>&1 1>&2 2>&3)

        RET=$?
        if [ $RET -ne 0 ]; then
            clear
            msg_warn "User selection cancelled by operator. Exiting."
            exit 0
        fi

        USER_INPUT=$(printf "%s" "$USER_INPUT" | tr -d '[:space:]')

        if [ -z "$USER_INPUT" ]; then
            bsddialog --backtitle "$BACKTITLE" \
                --title " Invalid Input " \
                --msgbox "The username field cannot be empty. Please enter a valid username." 7 60
            continue
        fi

        if ! pw usershow "$USER_INPUT" >/dev/null 2>&1; then
            bsddialog --backtitle "$BACKTITLE" \
                --title " User Not Found " \
                --default-no \
                --yes-label "Use Anyway" \
                --no-label "Re-enter" \
                --yesno "The user '${USER_INPUT}' does not currently exist on this system.\n\nDo you want to keep '${USER_INPUT}' anyway, or go back and enter an existing username?" 10 68
            if [ $? -ne 0 ]; then
                continue
            fi
        fi

        TARGET_USER="$USER_INPUT"
        BACKTITLE="FreeBSD 16 Workstation Setup v${SCRIPT_VERSION} (User: ${TARGET_USER}) - github.com/msartor99"
        log_raw "Target user set to: ${TARGET_USER}"
        break
    done
}

append_if_missing() {
    _file="$1"
    _pattern="$2"
    _line="$3"
    if [ ! -f "$_file" ]; then
        touch "$_file"
    fi
    if ! grep -Fq "$_pattern" "$_file" 2>/dev/null; then
        printf "%s\n" "$_line" >> "$_file"
        msg_ok "Added to $_file: $_line"
    else
        msg_info "Already present in $_file: $_pattern"
    fi
}

detect_gpu_model() {
    _gpu_info=""
    if command -v pciconf >/dev/null 2>&1; then
        _gpu_info=$(pciconf -lv 2>/dev/null | awk '
            /^[a-zA-Z0-9_]+@pci/ {
                in_block=1; vendor=""; device=""; class="";
            }
            in_block && /vendor[[:space:]]*=/ {
                sub(/.*vendor[[:space:]]*=[[:space:]]*\x27/, "");
                sub(/\x27.*/, "");
                vendor=$0;
            }
            in_block && /device[[:space:]]*=/ {
                sub(/.*device[[:space:]]*=[[:space:]]*\x27/, "");
                sub(/\x27.*/, "");
                device=$0;
            }
            in_block && /class[[:space:]]*=[[:space:]]*display/ {
                if (vendor != "" || device != "") {
                    printf "%s %s | ", vendor, device
                }
            }
        ' | sed 's/ | $//')
    fi
    if [ -z "$_gpu_info" ]; then
        _gpu_info="No VGA/Display controller detected via pciconf"
    fi
    printf "%s" "$_gpu_info"
}

# ==============================================================================
# CONFIGURATION MODULES
# ==============================================================================

do_sudo() {
    msg_info "=== [01_SUDO] Configuring sudo and wheel group access ==="
    run_cmd "Update pkg catalogue" pkg update
    pkg_install_logged "01_SUDO" sudo

    mkdir -p /usr/local/etc/sudoers.d
    printf "%%wheel ALL=(ALL:ALL) ALL\n" > /usr/local/etc/sudoers.d/wheel
    chmod 0440 /usr/local/etc/sudoers.d/wheel

    if pw usershow "$TARGET_USER" >/dev/null 2>&1; then
        run_cmd "Add $TARGET_USER to wheel,operator,video" pw usermod "$TARGET_USER" -G wheel,operator,video
    else
        msg_warn "User '$TARGET_USER' does not exist yet; skipping pw usermod."
    fi
}

do_base_ssh() {
    msg_info "=== [02_SSH] Configuring SSH root login and base system updates ==="
    if grep -Eq "^#?PermitRootLogin" /etc/ssh/sshd_config; then
        sed -i '' 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    else
        printf "\nPermitRootLogin yes\n" >> /etc/ssh/sshd_config
    fi
    run_cmd "Restart sshd" service sshd restart

    case "$(uname -r)" in
        *-CURRENT|*-ALPHA*|*-BETA*|*-RC*)
            msg_info "Skipping freebsd-update on $(uname -r) branch (not supported on CURRENT)."
            ;;
        *)
            if command -v freebsd-update >/dev/null 2>&1; then
                msg_info "Running freebsd-update (non-interactive)..."
                env PAGER=/bin/cat freebsd-update --not-running-from-cron fetch install >> "$LOG_FILE" 2>&1 || true
            fi
            ;;
    esac
    msg_ok "SSH configured."
}

do_silent_boot_sysctl() {
    msg_info "=== [03_BOOT] Applying silent boot and sysctl optimizations ==="
    run_cmd "Set boot_mute=YES" sysrc -f /boot/loader.conf boot_mute="YES"
    run_cmd "Set autoboot_delay=3" sysrc -f /boot/loader.conf autoboot_delay="3"
    run_cmd "Set tmpfs_load=YES" sysrc -f /boot/loader.conf tmpfs_load="YES"
    run_cmd "Set aio_load=YES" sysrc -f /boot/loader.conf aio_load="YES"

    run_cmd "Set splash_changer_enable=YES" sysrc splash_changer_enable="YES"
    run_cmd "Set rc_startmsgs=NO" sysrc rc_startmsgs="NO"

    if ! grep -Fq 'run_rc_script ${_rc_elem} ${_boot} > /dev/null' /etc/rc; then
        sed -i '' 's|run_rc_script ${_rc_elem} ${_boot}|run_rc_script ${_rc_elem} ${_boot} > /dev/null|g' /etc/rc
        msg_ok "Patched /etc/rc for silent startup."
    else
        msg_info "/etc/rc is already patched for silent startup."
    fi

    append_if_missing /etc/sysctl.conf "kern.ipc.shm_allow_removed" "kern.ipc.shm_allow_removed=1"
    append_if_missing /etc/sysctl.conf "net.local.stream.recvspace" "net.local.stream.recvspace=65536"
    append_if_missing /etc/sysctl.conf "net.local.stream.sendspace" "net.local.stream.sendspace=65536"

    sysctl net.local.stream.recvspace=65536 >> "$LOG_FILE" 2>&1 || true
    sysctl net.local.stream.sendspace=65536 >> "$LOG_FILE" 2>&1 || true
    sysctl kern.ipc.shm_allow_removed=1 >> "$LOG_FILE" 2>&1 || true
    msg_ok "Boot and sysctl settings applied."
}

do_cpu_microcode() {
    [ -z "$CPU_CHOICE" ] && return 0
    msg_info "=== [04_CPU] Installing CPU microcode and thermal sensors ($CPU_CHOICE) ==="
    pkg_install_logged "04_CPU" cpu-microcode
    pkg install -y sensors >> "$LOG_FILE" 2>&1 || pkg install -y bsdsensors >> "$LOG_FILE" 2>&1 || true

    case "$CPU_CHOICE" in
        INTEL)
            run_cmd "Enable coretemp" sysrc -f /boot/loader.conf coretemp_load="YES"
            run_cmd "Enable cpu_microcode" sysrc -f /boot/loader.conf cpu_microcode_load="YES"
            run_cmd "Set intel ucode" sysrc -f /boot/loader.conf cpu_microcode_name="/boot/firmware/intel-ucode.bin"
            kldload coretemp >> "$LOG_FILE" 2>&1 || true
            ;;
        AMD)
            run_cmd "Enable amdtemp" sysrc -f /boot/loader.conf amdtemp_load="YES"
            run_cmd "Enable cpu_microcode" sysrc -f /boot/loader.conf cpu_microcode_load="YES"
            run_cmd "Set amd ucode" sysrc -f /boot/loader.conf cpu_microcode_name="/boot/firmware/amd-ucode.bin"
            kldload amdtemp >> "$LOG_FILE" 2>&1 || true
            ;;
    esac
}

do_linux_compat() {
    msg_info "=== [05_LINUX] Enabling Linux binary compatibility ==="
    run_cmd "Enable linux_enable" sysrc linux_enable="YES"
    run_cmd "Enable linux64_enable" sysrc linux64_enable="YES"
    run_cmd "Enable linux_mounts_enable" sysrc linux_mounts_enable="YES"
    kldload linux >> "$LOG_FILE" 2>&1 || true
    kldload linux64 >> "$LOG_FILE" 2>&1 || true
    run_cmd "Start linux service" service linux start
}

do_cli_smartd() {
    msg_info "=== [06_UTILS] Installing CLI utilities and smartmontools ==="
    pkg_install_logged "06_UTILS" doas unzip libzip wget git htop fastfetch python3 btop smartmontools
    pkg install -y neofetch bashtop >> "$LOG_FILE" 2>&1 || true

    if [ ! -f /usr/local/etc/smartd.conf ] && [ -f /usr/local/etc/smartd.conf.sample ]; then
        cp /usr/local/etc/smartd.conf.sample /usr/local/etc/smartd.conf
    fi
    run_cmd "Enable smartd" sysrc smartd_enable="YES"
    service smartd start >> "$LOG_FILE" 2>&1 || true
}

do_french_locale() {
    msg_info "=== [07_LOCALE] Configuring French login class (UTF-8) ==="
    if ! grep -Fq "french|French Users Accounts:" /etc/login.conf; then
        cat >> /etc/login.conf << 'EOF'

french|French Users Accounts:\
	:charset=UTF-8:\
	:lang=fr_FR.UTF-8:\
	:setenv=LC_ALL=fr_FR.UTF-8,LC_COLLATE=fr_FR.UTF-8,LC_CTYPE=fr_FR.UTF-8,LC_MESSAGES=fr_FR.UTF-8:\
	:tc=default:
EOF
        run_cmd "Rebuild login.conf db" cap_mkdb /etc/login.conf
    else
        msg_info "French login class already exists in /etc/login.conf."
    fi

    append_if_missing /etc/adduser.conf "defaultclass=" "defaultclass=french"

    if pw usershow "$TARGET_USER" >/dev/null 2>&1; then
        run_cmd "Set French class for $TARGET_USER" pw usermod "$TARGET_USER" -G wheel,operator,video -L french
    fi
    run_cmd "Set French class for root" pw usermod root -L french
}

do_cups_usb() {
    msg_info "=== [08_CUPS_USB] Configuring CUPS printing, FUSE filesystems, and devfs rules ==="
    pkg_install_logged "08_CUPS_USB" cups gutenprint cups-filters hplip system-config-printer \
        fusefs-ntfs fusefs-ext2 fusefs-hfsfuse

    if ! grep -Fq "[localrules=5]" /etc/devfs.rules 2>/dev/null; then
        cat >> /etc/devfs.rules << 'EOF'

[localrules=5]
add path 'da*' mode 0660 group operator
add path 'cd*' mode 0660 group operator
add path 'uscanner*' mode 0660 group operator
add path 'xpt*' mode 0660 group operator
add path 'pass*' mode 0660 group operator
add path 'md*' mode 0660 group operator
add path 'msdosfs/*' mode 0660 group operator
add path 'ext2fs/*' mode 0660 group operator
add path 'ntfs/*' mode 0660 group operator
add path 'usb/*' mode 0660 group operator
add path 'video*' mode 0660 group operator
add path 'unlpt*' mode 0660 group cups
add path 'lpt*' mode 0660 group cups
EOF
        msg_ok "Added [localrules=5] to /etc/devfs.rules."
    else
        msg_info "[localrules=5] already present in /etc/devfs.rules."
    fi

    run_cmd "Enable cupsd" sysrc cupsd_enable="YES"
    run_cmd "Set devfs ruleset" sysrc devfs_system_ruleset="localrules"
    run_cmd "Add fusefs to kld_list" sysrc kld_list+="fusefs"
    run_cmd "Add ext2fs to kld_list" sysrc kld_list+="ext2fs"

    kldload fusefs >> "$LOG_FILE" 2>&1 || true
    kldload ext2fs >> "$LOG_FILE" 2>&1 || true

    append_if_missing /etc/sysctl.conf "vfs.usermount" "vfs.usermount=1"
    sysctl vfs.usermount=1 >> "$LOG_FILE" 2>&1 || true

    service devfs restart >> "$LOG_FILE" 2>&1 || true
    service cupsd start >> "$LOG_FILE" 2>&1 || true
}

configure_dbus_and_xdg_runtime() {
    msg_info "Configuring D-Bus machine-id, ConsoleKit2, Polkit, and XDG_RUNTIME_DIR..."
    pkg_install_logged "DBUS_XDG" dbus consolekit2 polkit seatd

    run_cmd "Enable dbus" sysrc dbus_enable="YES"
    run_cmd "Enable seatd" sysrc seatd_enable="YES"

    mkdir -p /var/lib/dbus
    dbus-uuidgen --ensure=/etc/machine-id >> "$LOG_FILE" 2>&1 || true
    dbus-uuidgen --ensure=/var/lib/dbus/machine-id >> "$LOG_FILE" 2>&1 || true

    if pw usershow "$TARGET_USER" >/dev/null 2>&1; then
        _uid=$(id -u "$TARGET_USER")
        mkdir -p "/var/run/user/${_uid}"
        chown "${TARGET_USER}:${TARGET_USER}" "/var/run/user/${_uid}"
        chmod 0700 "/var/run/user/${_uid}"
        msg_ok "Prepared /var/run/user/${_uid} (XDG_RUNTIME_DIR) for ${TARGET_USER}"
    fi

    if ! grep -Fq "XDG_RUNTIME_DIR" /etc/profile 2>/dev/null; then
        cat >> /etc/profile << 'EOF'

# Auto-configure XDG_RUNTIME_DIR for D-Bus, Plasma 6, and PipeWire
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/var/run/user/$(id -u)"
    if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
        chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    fi
fi
EOF
        msg_ok "Added automatic XDG_RUNTIME_DIR initialization to /etc/profile"
    fi

    service dbus restart >> "$LOG_FILE" 2>&1 || service dbus start >> "$LOG_FILE" 2>&1 || true
    service seatd restart >> "$LOG_FILE" 2>&1 || service seatd start >> "$LOG_FILE" 2>&1 || true
}

do_xorg_base() {
    msg_info "=== [09_XORG] Installing Xorg, D-Bus, Avahi, seatd, and Swiss-French keyboard ==="
    pkg_install_logged "09_XORG" xorg dbus avahi-app signal-cli seatd ImageMagick7 consolekit2 polkit

    configure_dbus_and_xdg_runtime
    run_cmd "Enable avahi_daemon" sysrc avahi_daemon_enable="YES"

    append_if_missing /etc/fstab "procfs" "proc            /proc           procfs          rw              0       0"
    append_if_missing /etc/fstab "fdescfs" "fdesc           /dev/fd         fdescfs         rw              0       0"
    mount -a >> "$LOG_FILE" 2>&1 || true

    mkdir -p /usr/local/etc/X11/xorg.conf.d
    cat > /usr/local/etc/X11/xorg.conf.d/20-keyboards.conf << 'EOF'
Section "ServerFlags"
    Option "DontZap" "false"
EndSection

Section "InputClass"
    Identifier      "All Keyboards"
    MatchIsKeyboard "yes"
    Option          "XkbLayout" "ch"
    Option          "XkbVariant" "fr"
    Option          "XkbOptions" "terminate:ctrl_alt_bksp"
EndSection
EOF
    msg_ok "Xorg base, D-Bus, and Swiss-French keyboard configured."
}

configure_nvidia_common() {
    run_cmd "Add nvidia-modeset to kld_list" sysrc kld_list+="nvidia-modeset"
    run_cmd "Enable nvidia_modeset" sysrc nvidia_modeset_enable="YES"

    append_if_missing /boot/loader.conf "hw.nvidiadrm.modeset" 'hw.nvidiadrm.modeset="1"'
    append_if_missing /boot/loader.conf "hw.nvidia.registry.EnableGpuFirmware" 'hw.nvidia.registry.EnableGpuFirmware="1"'

    nvidia-xconfig >> "$LOG_FILE" 2>&1 || true

    if [ "$NVIDIA_4K_CHOICE" = "YES" ]; then
        mkdir -p /usr/local/etc/X11/xorg.conf.d
        cat > /usr/local/etc/X11/xorg.conf.d/10-nvidia.conf << 'EOF'
Section "Device"
    Identifier     "NVIDIA Card"
    Driver         "nvidia"
    Option         "ModeValidation" "NoMaxResolutionCheck"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    VendorName     "Unknown"
    ModelName      "Unknown"
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "NVIDIA Card"
    Monitor        "Monitor0"
    DefaultDepth    24
    Option         "MetaModes" "2560x1440 +0+0"
    SubSection "Display"
        Depth       24
        Modes      "2560x1440"
    EndSubSection
EndSection
EOF
        msg_ok "Written /usr/local/etc/X11/xorg.conf.d/10-nvidia.conf (2560x1440)."
    fi
}

do_gpu_driver() {
    [ -z "$GPU_CHOICE" ] && return 0
    msg_info "=== [10_GPU] Installing GPU Driver ($GPU_CHOICE) ==="
    case "$GPU_CHOICE" in
        AMD_RECENT)
            pkg_install_logged "10_GPU" wayland xwayland drm-kmod
            run_cmd "Add amdgpu to kld_list" sysrc kld_list+="amdgpu"
            ;;
        AMD_LEGACY)
            pkg_install_logged "10_GPU" wayland xwayland drm-kmod
            run_cmd "Add radeonkms to kld_list" sysrc kld_list+="radeonkms"
            ;;
        NV_LATEST)
            do_linux_compat
            pkg_install_logged "10_GPU" nvidia-driver linux-nvidia-libs nvidia-kmod nvidia-drm-kmod libc6-shim nvidia-settings nvidia-xconfig
            configure_nvidia_common
            ;;
        NV_580)
            do_linux_compat
            pkg_install_logged "10_GPU" nvidia-driver-580 linux-nvidia-libs-580 nvidia-kmod-580 nvidia-drm-kmod-580 libc6-shim nvidia-settings nvidia-xconfig
            configure_nvidia_common
            ;;
        NV_470)
            do_linux_compat
            pkg_install_logged "10_GPU" nvidia-driver-470 linux-nvidia-libs-470 nvidia-kmod-470 nvidia-drm-kmod-470 libc6-shim nvidia-settings nvidia-xconfig
            configure_nvidia_common
            ;;
    esac
}

fetch_assets() {
    if [ ! -d "$ASSETS_DIR" ]; then
        pkg_install_logged "11_SDDM" git
        run_cmd "Clone assets repo" git clone "$ASSETS_REPO" "$ASSETS_DIR"
    fi
}

do_sddm_splash() {
    [ -z "$SPLASH_CHOICE" ] && return 0
    msg_info "=== [11_SDDM] Configuring SDDM and Boot Splash ($SPLASH_CHOICE) ==="
    pkg_install_logged "11_SDDM" sddm consolekit2 polkit
    configure_dbus_and_xdg_runtime

    run_cmd "Enable sddm" sysrc sddm_enable="YES"
    run_cmd "Set sddm_lang=fr_FR.UTF-8" sysrc sddm_lang="fr_FR.UTF-8"

    mkdir -p /usr/local/share/sddm/scripts
    append_if_missing /usr/local/share/sddm/scripts/Xsetup "setxkbmap ch fr" "setxkbmap ch fr"

    mkdir -p /usr/local/etc/sddm.conf.d
    cat > /usr/local/etc/sddm.conf << 'EOF'
[General]
InputMethod=
EOF

    case "$SPLASH_CHOICE" in
        MALDIVES)
            cat > /usr/local/etc/sddm.conf.d/theme.conf << 'EOF'
[Theme]
Current=maldives
EOF
            msg_ok "SDDM configured with Maldives theme."
            ;;
        NASA)
            fetch_assets
            mkdir -p /usr/local/share/sddm/themes/nasa
            if [ -d /usr/local/share/sddm/themes/maldives ]; then
                cp -R /usr/local/share/sddm/themes/maldives/* /usr/local/share/sddm/themes/nasa/ 2>/dev/null || true
            fi
            rm -f /usr/local/share/sddm/themes/nasa/*.jpg
            cp -f "$ASSETS_DIR/Main.qml" /usr/local/share/sddm/themes/nasa/
            cp -f "$ASSETS_DIR/metadata.desktop" /usr/local/share/sddm/themes/nasa/
            cp -f "$ASSETS_DIR/nasa2560login.jpg" /usr/local/share/sddm/themes/nasa/background.jpg

            cat > /usr/local/etc/sddm.conf.d/theme.conf << 'EOF'
[Theme]
Current=nasa

[General]
InputMethod=
background=background.png
displayFont="Montserrat"
EOF
            mkdir -p /boot/images
            cp -f "$ASSETS_DIR/freebsd-brand-rev.png" /boot/images/
            cp -f "$ASSETS_DIR/freebsd-logo-rev.png" /boot/images/
            cp -f "$ASSETS_DIR/nasa1920.png" /boot/images/splash.png
            run_cmd "Set boot splash" sysrc -f /boot/loader.conf splash="/boot/images/splash.png"
            run_cmd "Set shutdown splash" sysrc -f /boot/loader.conf shutdown_splash="/boot/images/splash.png"
            ;;
        KAMILA)
            pkg_install_logged "11_SDDM" ImageMagick7 wget
            mkdir -p /boot/images
            run_cmd "Download Kamila splash" wget -O /tmp/v2.png https://kamila.is/media/v2.png
            run_cmd "Resize splash image" magick /tmp/v2.png -resize 1920x1200 /boot/images/splash.png
            run_cmd "Set boot splash" sysrc -f /boot/loader.conf splash="/boot/images/splash.png"
            run_cmd "Set shutdown splash" sysrc -f /boot/loader.conf shutdown_splash="/boot/images/splash.png"
            ;;
    esac
}

do_desktop_env() {
    [ -z "$DE_CHOICE" ] && return 0
    msg_info "=== [12_DE] Installing Desktop Environment ($DE_CHOICE) ==="

    configure_dbus_and_xdg_runtime

    case "$DE_CHOICE" in
        PLASMA6)
            pkg_install_glob_logged "12_DE" "plasma6-*"
            pkg_install_glob_logged "12_DE" "kf6-*"
            pkg_install_logged "12_DE" wayland xwayland pavucontrol kate konsole ark remmina dolphin Kvantum

            if [ -f /usr/local/share/xsessions/plasmax11.desktop ] || [ -f /usr/local/share/wayland-sessions/plasma.desktop ]; then
                msg_ok "Verified: KDE Plasma 6 session files are registered for SDDM"
            else
                msg_err "Plasma 6 session files not found in /usr/local/share/xsessions or wayland-sessions!"
            fi
            ;;
        XFCE)
            pkg_install_logged "12_DE" xfce xfce4-goodies
            pkg_install_glob_logged "12_DE" "xfce4-*"
            ;;
        CINNAMON)
            pkg_install_logged "12_DE" cinnamon
            ;;
        ALFIX)
            fetch -o /tmp/desktop https://gitlab.com/alfix/kde-installer-dialogs/-/raw/main/desktop
            chmod +x /tmp/desktop
            sh /tmp/desktop
            ;;
    esac
}

do_audio() {
    msg_info "=== [13_AUDIO] Configuring Audio (Exact Todo List Configuration) ==="

    # IMPORTANT: Never run 'pkg delete -y alsa-plugins' without '-f'!
    # On FreeBSD 16, qt6-multimedia / plasma6-plasma-workspace depend on alsa-plugins
    # via pulseaudio/pipewire chains, so 'pkg delete -y alsa-plugins' cascades and
    # uninstalls plasma6-plasma-workspace (removing Plasma 6 from SDDM)!
    sysrc -f /boot/loader.conf -x snd_uaudio_load >> "$LOG_FILE" 2>&1 || true
    sed -i '' '/hw.snd.default_auto/d' /etc/sysctl.conf 2>/dev/null || true

    # Exact packages from original todo list
    pkg_install_logged "13_AUDIO" pulseaudio pipewire wireplumber audio/freedesktop-sound-theme

    # Ensure plasma6-plasma-workspace & plasma6-plasma-pa remain present if Plasma 6 is used
    if pkg info -e plasma6-kwin >/dev/null 2>&1 && ! [ -f /usr/local/share/wayland-sessions/plasma.desktop ]; then
        msg_warn "Restoring Plasma 6 workspace session files removed by previous pkg delete..."
        pkg_install_logged "13_AUDIO_RESTORE_PLASMA" plasma6-plasma plasma6-plasma-workspace plasma6-plasma-desktop plasma6-plasma-pa
    fi

    # Exact sysrc commands from original todo list (+ loader.conf persistence)
    run_cmd "Set sound_load=YES in rc.conf" sysrc sound_load="YES"
    run_cmd "Set snd_hda_load=YES in rc.conf" sysrc snd_hda_load="YES"
    run_cmd "Set sound_load=YES in loader.conf" sysrc -f /boot/loader.conf sound_load="YES"
    run_cmd "Set snd_hda_load=YES in loader.conf" sysrc -f /boot/loader.conf snd_hda_load="YES"

    kldload sound >> "$LOG_FILE" 2>&1 || true
    kldload snd_hda >> "$LOG_FILE" 2>&1 || true

    # Exact sysctl from original todo list: hw.snd.default_unit=1
    sysctl hw.snd.default_auto=0 >> "$LOG_FILE" 2>&1 || true
    run_cmd "Set hw.snd.default_unit=1" sysctl hw.snd.default_unit=1
    sed -i '' '/hw.snd.default_unit/d' /etc/sysctl.conf 2>/dev/null || true
    append_if_missing /etc/sysctl.conf "hw.snd.default_unit" "hw.snd.default_unit=1"

    msg_ok "Audio configured strictly according to original todo list (hw.snd.default_unit=1)."
}

do_apps_base() {
    msg_info "=== [14_APPS] Installing Desktop Applications, LibreOffice, and Base Fonts ==="
    pkg_install_logged "14_APPS" firefox chromium thunderbird vlc ffmpeg multimedia/mpv \
        libva-vdpau-driver libva-utils libdvdread libdvdnav libbluray \
        gstreamer1-plugins-all gstreamer1-libav \
        signal-cli eom remmina xdg-user-dirs octopkg \
        webcamd v4l-utils kdenlive ImageMagick7 libreoffice \
        cantarell-fonts droid-fonts-ttf inconsolata-ttf noto-basic noto-emoji \
        roboto-fonts-ttf ubuntu-font \
        papirus-icon-theme qogir-icon-themes win98se-icon-theme

    if command -v libreoffice >/dev/null 2>&1 || command -v soffice >/dev/null 2>&1; then
        msg_ok "Verified: LibreOffice binary is installed and available in PATH."
    else
        msg_err "Verification failed: LibreOffice binary was not found after installation!"
    fi

    run_cmd "Enable webcamd" sysrc webcamd_enable="YES"
}

do_extra_fonts() {
    msg_info "=== [15_FONTS] Installing Optional Extra & International Fonts ==="
    pkg_install_logged "15_FONTS" webfonts terminus-font terminus-ttf \
        x11-fonts/dejavu x11-fonts/anonymous-pro x11-fonts/Gentium x11-fonts/nerd-fonts \
        twemoji-color-font-ttf textproc/ibus-uniemoji \
        x11-themes/cursor-neutral-white-theme

    pkg_install_logged "15_INTL_FONTS" chinese/arphicttf chinese/font-std \
        hebrew/culmus hebrew/elmar-fonts \
        japanese/font-ipa japanese/font-ipa-uigothic japanese/font-ipaex \
        japanese/font-kochi japanese/font-migmix japanese/font-migu \
        japanese/font-mona-ipa japanese/font-motoya-al japanese/font-mplus-ipa \
        japanese/font-sazanami japanese/font-shinonome japanese/font-takao \
        japanese/font-ume japanese/font-vlgothic x11-fonts/hanazono-fonts-ttf \
        japanese/font-mikachan korean/aleefonts-ttf korean/nanumfonts \
        korean/unfonts-core x11-fonts/artwiz-aleczapka x11-fonts/doulos \
        x11-fonts/isabella x11-fonts/junicode x11-fonts/khmeros x11-fonts/padauk \
        x11-fonts/stix-fonts x11-fonts/charis x11-fonts/urwfonts-ttf \
        russian/koi8r-ps x11-fonts/geminifonts x11-fonts/cyr-rfx x11-fonts/paratype
}

do_samba() {
    msg_info "=== [16_SAMBA] Configuring Samba File Server (/home/share) ==="
    if pkg install -y samba420 >> "$LOG_FILE" 2>&1; then
        msg_ok "[16_SAMBA] Installed samba420"
    elif pkg install -y samba419 >> "$LOG_FILE" 2>&1; then
        msg_ok "[16_SAMBA] Installed samba419"
    else
        pkg_install_logged "16_SAMBA" samba416
    fi

    mkdir -p /home/share
    chmod 0777 /home/share

    if [ ! -f /usr/local/etc/smb4.conf ] || ! grep -Fq "[Share]" /usr/local/etc/smb4.conf; then
        cat > /usr/local/etc/smb4.conf << EOF
[global]
    unix charset = UTF-8
    workgroup = HOMELAB
    server string = FreeBSD Workstation
    interfaces = 127.0.0.0/8 ${SAMBA_SUBNET}
    bind interfaces only = yes
    map to guest = bad user

[Share]
    path = /home/share
    writable = yes
    guest ok = yes
    guest only = yes
    force create mode = 0777
    force directory mode = 0777
EOF
        msg_ok "Created /usr/local/etc/smb4.conf."
    else
        msg_info "/usr/local/etc/smb4.conf already contains [Share]."
    fi

    run_cmd "Enable samba_server" sysrc samba_server_enable="YES"
    run_cmd "Start samba_server" service samba_server restart
}

do_xrdp() {
    msg_info "=== [17_XRDP] Configuring XRDP Remote Desktop Server ==="
    pkg_install_logged "17_XRDP" xrdp xorgxrdp
    run_cmd "Enable xrdp" sysrc xrdp_enable="YES"
    run_cmd "Enable xrdp_sesman" sysrc xrdp_sesman_enable="YES"

    if [ -f /usr/local/etc/xrdp/startwm.sh ] && [ ! -f /usr/local/etc/xrdp/startwm.sh.backup ]; then
        cp /usr/local/etc/xrdp/startwm.sh /usr/local/etc/xrdp/startwm.sh.backup
    fi

    mkdir -p /usr/local/etc/xrdp
    cat > /usr/local/etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
export LANG=fr_FR.UTF-8
export LC_ALL=fr_FR.UTF-8
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/var/run/user/$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
exec ck-launch-session dbus-launch --exit-with-session startplasma-x11
EOF
    chmod 0555 /usr/local/etc/xrdp/startwm.sh
    msg_ok "XRDP configured for Plasma X11 with ConsoleKit2 and D-Bus."
}

do_pkg_branch() {
    [ -z "$PKG_CHOICE" ] && return 0
    msg_info "=== [18_PKG] Switching pkg repository branch ($PKG_CHOICE) ==="
    mkdir -p /usr/local/etc/pkg/repos
    case "$PKG_CHOICE" in
        LATEST)
            cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOF'
FreeBSD: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/latest"
}
EOF
            run_cmd "Update pkg catalogue (latest)" pkg update -f
            run_cmd "Upgrade packages (latest)" pkg upgrade -y
            ;;
        QUARTERLY)
            cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOF'
FreeBSD: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/quarterly"
}
EOF
            run_cmd "Update pkg catalogue (quarterly)" pkg update -f
            ;;
    esac
}

do_virtualbox() {
    msg_info "=== [19_VBOX] Installing and configuring VirtualBox 7 ==="
    if ! pkg install -y virtualbox-ose-72 >> "$LOG_FILE" 2>&1; then
        pkg_install_logged "19_VBOX" virtualbox-ose
    else
        msg_ok "[19_VBOX] Installed virtualbox-ose-72"
    fi

    run_cmd "Enable vboxdrv_load" sysrc -f /boot/loader.conf vboxdrv_load="YES"
    run_cmd "Enable vboxnet_load" sysrc -f /boot/loader.conf vboxnet_load="YES"
    run_cmd "Enable vboxnet_enable" sysrc vboxnet_enable="YES"

    kldload vboxdrv >> "$LOG_FILE" 2>&1 || true
    kldload vboxnetflt >> "$LOG_FILE" 2>&1 || true
    kldload vboxnetadp >> "$LOG_FILE" 2>&1 || true

    pw groupmod vboxusers -m root >> "$LOG_FILE" 2>&1 || true
    if pw usershow "$TARGET_USER" >/dev/null 2>&1; then
        run_cmd "Add $TARGET_USER to vboxusers" pw groupmod vboxusers -m "$TARGET_USER"
    fi

    if [ -e /dev/vboxnetctl ]; then
        chown root:vboxusers /dev/vboxnetctl
        chmod 0660 /dev/vboxnetctl
    fi

    append_if_missing /etc/devfs.conf "own     vboxnetctl" "own     vboxnetctl root:vboxusers"
    append_if_missing /etc/devfs.conf "perm    vboxnetctl" "perm    vboxnetctl 0660"

    service devfs restart >> "$LOG_FILE" 2>&1 || true
}

# ==============================================================================
# SUBMENUS TRIGGERED AFTER CHECKLIST CONFIRMATION
# ==============================================================================

ask_cpu_submenu() {
    CPU_CHOICE=$(bsddialog --backtitle "$BACKTITLE" \
        --title " [04_CPU] CPU Microcode & Thermal Driver " \
        --ok-label "Select" \
        --cancel-label "Skip" \
        --menu "Select your workstation CPU architecture:" 12 65 2 \
        "AMD"   "AMD Processor (amdtemp + amd-ucode.bin)" \
        "INTEL" "Intel Processor (coretemp + intel-ucode.bin)" \
        3>&1 1>&2 2>&3) || CPU_CHOICE=""
    log_raw "Submenu CPU_CHOICE=${CPU_CHOICE}"
}

ask_gpu_submenu() {
    GPU_MODEL=$(detect_gpu_model)
    GPU_HINT="Select the matching driver below."
    case "$GPU_MODEL" in
        *NVIDIA*|*GeForce*|*Quadro*|*RTX*|*GTX*)
            GPU_HINT="NVIDIA GPU detected -> Choose NV_LATEST, NV_580, or NV_470."
            ;;
        *AMD*|*ATI*|*Radeon*)
            GPU_HINT="AMD GPU detected -> Choose AMD_RECENT (amdgpu) or AMD_LEGACY."
            ;;
    esac

    GPU_CHOICE=$(bsddialog --backtitle "$BACKTITLE" \
        --title " [10_GPU] Graphics Card Driver Selection " \
        --ok-label "Select" \
        --cancel-label "Skip" \
        --menu "Detected GPU Model(s):\n  ${GPU_MODEL}\n\n${GPU_HINT}" 17 78 5 \
        "NV_LATEST"  "NVIDIA Driver - Latest (nvidia-driver + drm-kmod)" \
        "NV_580"     "NVIDIA Driver - 580 Branch (nvidia-driver-580)" \
        "NV_470"     "NVIDIA Driver - 470 Legacy (nvidia-driver-470)" \
        "AMD_RECENT" "AMD Recent GPU (drm-kmod -> amdgpu + Wayland)" \
        "AMD_LEGACY" "AMD Legacy GPU / Radeon RX 5500 (radeonkms)" \
        3>&1 1>&2 2>&3) || GPU_CHOICE=""
    log_raw "Submenu GPU_CHOICE=${GPU_CHOICE} (Detected: ${GPU_MODEL})"

    case "$GPU_CHOICE" in
        NV_*)
            if bsddialog --backtitle "$BACKTITLE" \
                --title " [10_GPU] NVIDIA 27-inch 4K -> 2560x1440 MetaMode " \
                --default-no \
                --yesno "Do you want to generate /usr/local/etc/X11/xorg.conf.d/10-nvidia.conf to lock the resolution to 2560x1440 (27-inch 4K monitor fix)?" 9 72; then
                NVIDIA_4K_CHOICE="YES"
            else
                NVIDIA_4K_CHOICE="NO"
            fi
            log_raw "Submenu NVIDIA_4K_CHOICE=${NVIDIA_4K_CHOICE}"
            ;;
    esac
}

ask_splash_submenu() {
    SPLASH_CHOICE=$(bsddialog --backtitle "$BACKTITLE" \
        --title " [11_SDDM] SDDM Theme & Boot Splash " \
        --ok-label "Select" \
        --cancel-label "Skip" \
        --menu "Choose SDDM login theme and boot splash screen:" 13 72 3 \
        "NASA"     "SDDM NASA Custom Theme + NASA Boot Splash" \
        "MALDIVES" "SDDM Maldives Theme (Standard)" \
        "KAMILA"   "Kamila.is Boot Splash (1920x1200 via ImageMagick7)" \
        3>&1 1>&2 2>&3) || SPLASH_CHOICE=""
    log_raw "Submenu SPLASH_CHOICE=${SPLASH_CHOICE}"
}

ask_de_submenu() {
    DE_CHOICE=$(bsddialog --backtitle "$BACKTITLE" \
        --title " [12_DE] Desktop Environment Selection " \
        --ok-label "Select" \
        --cancel-label "Skip" \
        --menu "Choose the Desktop Environment to install:" 14 72 4 \
        "PLASMA6"  "KDE Plasma 6 (plasma6-* + kf6-* + Dolphin/Konsole/Kate)" \
        "XFCE"     "XFCE4 Desktop (xfce + xfce4-goodies)" \
        "CINNAMON" "Cinnamon Desktop" \
        "ALFIX"    "Alfix KDE/Wayland Dialog Installer" \
        3>&1 1>&2 2>&3) || DE_CHOICE=""
    log_raw "Submenu DE_CHOICE=${DE_CHOICE}"
}

ask_pkg_submenu() {
    PKG_CHOICE=$(bsddialog --backtitle "$BACKTITLE" \
        --title " [18_PKG] Package Repository Branch " \
        --ok-label "Select" \
        --cancel-label "Skip" \
        --menu "Select FreeBSD pkg repository branch:" 12 68 2 \
        "LATEST"    "Switch to LATEST branch and upgrade all packages" \
        "QUARTERLY" "Switch back to QUARTERLY branch" \
        3>&1 1>&2 2>&3) || PKG_CHOICE=""
    log_raw "Submenu PKG_CHOICE=${PKG_CHOICE}"
}

# ==============================================================================
# MAIN CHECKLIST WORKFLOW
# ==============================================================================

main_loop() {
    while true; do
        SELECTIONS=$(bsddialog --backtitle "$BACKTITLE" \
            --title " FreeBSD 16 Workstation Setup v${SCRIPT_VERSION} - Checklist " \
            --ok-label "Run Selected" \
            --cancel-label "Exit" \
            --checklist "Target User: ${TARGET_USER} | Log: ${LOG_FILE}\nUse SPACE to toggle options, ENTER to configure & run:" 24 84 16 \
            "01_SUDO"     "Install sudo & grant %wheel access (${TARGET_USER})" on \
            "02_SSH"      "Enable SSH Root Login & run freebsd-update" on \
            "03_BOOT"     "Silent Boot, Loader delays & IPC/Stream Sysctls" on \
            "04_CPU"      "CPU Microcode & Thermal Sensors (Submenu)" on \
            "05_LINUX"    "Enable Linux Binary Compatibility (linux / linux64)" on \
            "06_UTILS"    "Install CLI Tools (doas, git, htop, btop) & smartd" on \
            "07_LOCALE"   "Configure French UTF-8 Login Class (login.conf)" on \
            "08_CUPS_USB" "Install CUPS Printer Support & USB/FUSE Automount" on \
            "09_XORG"     "Install Xorg, D-Bus, ConsoleKit2 & Swiss-French Keyboard" on \
            "10_GPU"      "Graphics Card Driver Installation (Submenu after Enter)" on \
            "11_SDDM"     "Install SDDM Display Manager & Boot Splash (Submenu)" on \
            "12_DE"       "Install Desktop Environment: Plasma 6 / XFCE (Submenu)" on \
            "13_AUDIO"    "Configure Audio (pulseaudio, pipewire, snd_hda, unit=1)" on \
            "14_APPS"     "Install Base Apps (Firefox, VLC, LibreOffice) & Base Fonts" on \
            "15_FONTS"    "Install Extra & International Fonts (Nerd-Fonts, CJK)" off \
            "16_SAMBA"    "Install & Configure Samba Server (4.20/4.19)" off \
            "17_XRDP"     "Install & Configure XRDP Server (Plasma X11)" off \
            "18_PKG"      "Switch pkg Repo Branch: Latest / Quarterly (Submenu)" off \
            "19_VBOX"     "Install & Configure VirtualBox 7 (vboxdrv, vboxnet)" off \
            3>&1 1>&2 2>&3)

        RET=$?
        if [ $RET -ne 0 ]; then
            clear
            msg_ok "Exited FreeBSD 16 Workstation Setup v${SCRIPT_VERSION}. Log: ${LOG_FILE}"
            exit 0
        fi

        CLEAN_SEL=$(printf "%s" "$SELECTIONS" | tr -d '"')
        log_raw "Selected checklist items: ${CLEAN_SEL}"

        if [ -z "$CLEAN_SEL" ]; then
            bsddialog --backtitle "$BACKTITLE" \
                --title " No Options Selected " \
                --msgbox "Please select at least one option using the SPACE bar before pressing ENTER." 8 64
            continue
        fi

        # Trigger secondary submenus for selected items that need user choices
        for item in $CLEAN_SEL; do
            case "$item" in
                04_CPU)  ask_cpu_submenu ;;
                10_GPU)  ask_gpu_submenu ;;
                11_SDDM) ask_splash_submenu ;;
                12_DE)   ask_de_submenu ;;
                18_PKG)  ask_pkg_submenu ;;
            esac
        done

        clear
        ERROR_COUNT=0
        msg_info "Starting batch configuration (v${SCRIPT_VERSION}) for user '${TARGET_USER}'..."
        msg_info "Live log file: ${LOG_FILE} (and ${PERSISTENT_LOG})"

        for item in $CLEAN_SEL; do
            case "$item" in
                01_SUDO)     do_sudo ;;
                02_SSH)      do_base_ssh ;;
                03_BOOT)     do_silent_boot_sysctl ;;
                04_CPU)      do_cpu_microcode ;;
                05_LINUX)    do_linux_compat ;;
                06_UTILS)    do_cli_smartd ;;
                07_LOCALE)   do_french_locale ;;
                08_CUPS_USB) do_cups_usb ;;
                09_XORG)     do_xorg_base ;;
                10_GPU)      do_gpu_driver ;;
                11_SDDM)     do_sddm_splash ;;
                12_DE)       do_desktop_env ;;
                13_AUDIO)    do_audio ;;
                14_APPS)     do_apps_base ;;
                15_FONTS)    do_extra_fonts ;;
                16_SAMBA)    do_samba ;;
                17_XRDP)     do_xrdp ;;
                18_PKG)      do_pkg_branch ;;
                19_VBOX)     do_virtualbox ;;
            esac
        done

        cat >> "$LOG_FILE" <<EOF

==============================================================================
Execution Summary - Finished at $(date '+%Y-%m-%d %H:%M:%S')
Total Errors Recorded: ${ERROR_COUNT}
==============================================================================
EOF
        sync_log

        if [ "$ERROR_COUNT" -eq 0 ]; then
            SUMMARY_STATUS="SUCCESS: All selected tasks completed with 0 errors."
        else
            SUMMARY_STATUS="WARNING: Completed with ${ERROR_COUNT} error(s). Please inspect the log!"
        fi

        bsddialog --backtitle "$BACKTITLE" \
            --title " Execution Complete (v${SCRIPT_VERSION}) " \
            --yes-label "View Log (/tmp)" \
            --no-label "Back to Menu" \
            --yesno "${SUMMARY_STATUS}\n\nLog files saved to:\n  - ${LOG_FILE}\n  - ${PERSISTENT_LOG} (survives reboot)\n\nWould you like to view the execution log now?" 14 76

        if [ $? -eq 0 ]; then
            bsddialog --backtitle "$BACKTITLE" \
                --title " Log Viewer: ${LOG_FILE} " \
                --ok-label "Close Log" \
                --textbox "$LOG_FILE" 24 86
        fi
    done
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
check_root
check_bsddialog
init_log
show_disclaimer
ask_target_user
main_loop