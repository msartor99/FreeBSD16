#!/bin/sh
set -eu

# ==============================================================================
# Script post-installation FreeBSD 16 - Workstation Plasma 6 / Wayland & X11 / GPU
# Createur    : Gemini (IA)
# Superviseur : msartor99@gmail.com
# Version     : 1.7
# ==============================================================================

SCRIPT_VERSION="1.7"
SUPERVISOR_EMAIL="msartor99@gmail.com"
BACKTITLE="FreeBSD 16 Workstation Post-Install v${SCRIPT_VERSION} - Supervise par ${SUPERVISOR_EMAIL}"

LOADER_CONF="/boot/loader.conf"
RC_CONF="/etc/rc.conf"
SYSCTL_CONF="/etc/sysctl.conf"
FSTAB="/etc/fstab"
DEVFS_RULES="/etc/devfs.rules"
NSSWITCH_CONF="/etc/nsswitch.conf"
LOGIN_CONF="/etc/login.conf"
ADDUSER_CONF="/etc/adduser.conf"
SSHD_CONF="/etc/ssh/sshd_config"
AVAHI_CONF="/usr/local/etc/avahi/avahi-daemon.conf"

SDDM_THEMES_DIR="/usr/local/share/sddm/themes"
NASA_THEME_DIR="${SDDM_THEMES_DIR}/nasa"
GITHUB_RAW_BASE="https://github.com/msartor99/FreeBSD14/raw/main"

# ==============================================================================
# 0. VERIFICATIONS PRELIMINAIRES (BSDDIALOG, ROOT & DISCLAIMER)
# ==============================================================================
if ! command -v bsddialog >/dev/null 2>&1; then
    printf "Erreur : l'utilitaire natif bsddialog est introuvable.\n" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    bsddialog --backtitle "${BACKTITLE}" \
        --title "Erreur de privileges" \
        --msgbox "Ce script doit obligatoirement etre execute en tant que root." 7 60
    exit 1
fi

# Affichage du Disclaimer avec acceptation obligatoire Oui / Non
if ! bsddialog --backtitle "${BACKTITLE}" \
    --title "AVERTISSEMENT / DISCLAIMER (v${SCRIPT_VERSION})" \
    --yes-label "Oui, j'accepte" \
    --no-label "Non, quitter" \
    --yesno "AVIS IMPORTANT A L'OPERATEUR :\n\n\
Ce script post-installation pour FreeBSD 16 a ete cree par l'assistant IA Gemini et est supervise par : ${SUPERVISOR_EMAIL}\n\n\
Il modifie automatiquement la configuration systeme (/boot/loader.conf, /etc/rc.conf, /etc/sysctl.conf, /etc/fstab, /etc/login.conf, /etc/adduser.conf, /etc/devfs.rules, /etc/ssh/sshd_config) et installe le microcode CPU, Linuxulator, le pilote GPU choisi (NVIDIA 470/580/latest, Intel ou AMD), Xorg, KDE Plasma 6, SDDM (avec le theme personnalise 'nasa'), PipeWire/PulseAudio, l'automontage (FAT32/NTFS/exFAT/EXT2/HFS+) et les services d'impression (CUPS/Gutenprint/HPLIP).\n\n\
Ce script est fourni \"TEL QUEL\", sans aucune garantie expresse ou implicite. L'execution de ce script s'effectue sous votre entiere responsabilite.\n\n\
Acceptez-vous ces conditions et souhaitez-vous poursuivre l'installation ?" 21 78; then
    bsddialog --backtitle "${BACKTITLE}" \
        --title "Operation annulee" \
        --msgbox "Vous avez refuse les conditions du disclaimer. Aucune modification n'a ete apportee au systeme." 8 65
    exit 0
fi

# Fonctions utilitaires idempotentes (sans masquage des sorties)
print_step() {
    printf "\n==============================================================================\n"
    printf "==> %s\n" "$1"
    printf "==============================================================================\n"
}

add_line_if_missing() {
    _file="$1"
    _line="$2"
    if [ ! -f "${_file}" ]; then
        touch "${_file}"
    fi
    if ! grep -Fqx "${_line}" "${_file}"; then
        printf "%s\n" "${_line}" >> "${_file}"
        printf "[AJOUT] %s -> %s\n" "${_line}" "${_file}"
    else
        printf "[DEJA PRESENT] %s dans %s\n" "${_line}" "${_file}"
    fi
}

set_kv_config() {
    _file="$1"
    _key="$2"
    _val="$3"
    _escaped_key="$(printf "%s" "${_key}" | sed 's/\./\\./g')"
    if [ ! -f "${_file}" ]; then
        touch "${_file}"
    fi
    if grep -Eq "^[[:space:]]*${_escaped_key}=" "${_file}"; then
        sed -i '' "s|^[[:space:]]*${_escaped_key}=.*|${_key}=${_val}|" "${_file}"
        printf "[MAJ] %s=%s dans %s\n" "${_key}" "${_val}" "${_file}"
    else
        printf "%s=%s\n" "${_key}" "${_val}" >> "${_file}"
        printf "[AJOUT] %s=%s dans %s\n" "${_key}" "${_val}" "${_file}"
    fi
}

remove_kv_config() {
    _file="$1"
    _key="$2"
    _escaped_key="$(printf "%s" "${_key}" | sed 's/\./\\./g')"
    if [ -f "${_file}" ]; then
        sed -i '' "/^[[:space:]]*${_escaped_key}=/d" "${_file}"
        printf "[RETRAIT] %s de %s\n" "${_key}" "${_file}"
    fi
}

# Installation avec affichage complet en temps reel dans le terminal
install_verified_pkgs() {
    _valid_list=""
    for _pkg in "$@"; do
        printf "Verification de la disponibilite du paquet : %s ... " "${_pkg}"
        if pkg rquery "%n-%v" "${_pkg}"; then
            _valid_list="${_valid_list} ${_pkg}"
        else
            printf "ABSENT DU DEPOT (ignore)\n"
        fi
    done

    if [ -n "${_valid_list}" ]; then
        printf "\nLancement de : pkg install -y%s\n" "${_valid_list}"
        # shellcheck disable=SC2086
        env ASSUME_ALWAYS_YES=yes pkg install -y ${_valid_list}
    fi
}

# ==============================================================================
# 1. DETECTION DU PREMIER UTILISATEUR CREE (UID 1000 OU PREMIER UID >= 1000)
# ==============================================================================
DETECTED_USER="$(getent passwd | awk -F: '$3 == 1000 && $1 != "nobody" { print $1; exit }')"

if [ -z "${DETECTED_USER}" ]; then
    DETECTED_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody" && $7 !~ /(nologin|false)$/ { print $1; exit }')"
fi

TARGET_USER="$(bsddialog --backtitle "${BACKTITLE}" \
    --title "Selection de l'utilisateur" \
    --inputbox "Confirmez ou modifiez le nom du premier utilisateur cree lors de l'installation (UID 1000/1001 detecte) :" \
    10 70 "${DETECTED_USER}" 3>&1 1>&2 2>&3)" || exit 1

if [ -z "${TARGET_USER}" ] || ! pw user show "${TARGET_USER}"; then
    bsddialog --backtitle "${BACKTITLE}" \
        --title "Utilisateur introuvable" \
        --msgbox "L'utilisateur '${TARGET_USER}' n'existe pas dans /etc/passwd. Operation annulee." 8 65
    exit 1
fi

TARGET_UID="$(pw user show "${TARGET_USER}" | awk -F: '{print $3}')"

# ==============================================================================
# 2. DETECTION DU CLAVIER ET DE LA LANGUE DE L'INSTALLATEUR (bsdinstall)
# ==============================================================================
RAW_KEYMAP="$(sysrc -n keymap || true)"
RAW_KEYMAP="${RAW_KEYMAP%.kbd}"

XKB_LAYOUT="ch"
XKB_VARIANT="fr"
SYS_LOCALE="fr_CH.UTF-8"

case "${RAW_KEYMAP}" in
    ch.acc|ch|swissfrench*|ch-fr*)
        XKB_LAYOUT="ch"
        XKB_VARIANT="fr"
        SYS_LOCALE="fr_CH.UTF-8"
        ;;
    ch.macbook*)
        XKB_LAYOUT="ch"
        XKB_VARIANT="fr_mac"
        SYS_LOCALE="fr_CH.UTF-8"
        ;;
    de.ch*|swissgerman*)
        XKB_LAYOUT="ch"
        XKB_VARIANT=""
        SYS_LOCALE="de_CH.UTF-8"
        ;;
    fr.acc|fr|fr.macbook*)
        XKB_LAYOUT="fr"
        XKB_VARIANT=""
        SYS_LOCALE="fr_FR.UTF-8"
        ;;
    be.acc|be*)
        XKB_LAYOUT="be"
        XKB_VARIANT=""
        SYS_LOCALE="fr_BE.UTF-8"
        ;;
    ca-fr*|ca*)
        XKB_LAYOUT="ca"
        XKB_VARIANT="fr"
        SYS_LOCALE="fr_CA.UTF-8"
        ;;
    us*)
        XKB_LAYOUT="us"
        XKB_VARIANT=""
        SYS_LOCALE="en_US.UTF-8"
        ;;
    *)
        if [ -n "${LANG:-}" ] && [ "${LANG:-}" != "C" ] && [ "${LANG:-}" != "C.UTF-8" ]; then
            SYS_LOCALE="${LANG}"
        fi
        case "${RAW_KEYMAP}" in
            fr*) XKB_LAYOUT="fr"; XKB_VARIANT=""; SYS_LOCALE="fr_FR.UTF-8" ;;
            ch*) XKB_LAYOUT="ch"; XKB_VARIANT="fr"; SYS_LOCALE="fr_CH.UTF-8" ;;
        esac
        ;;
esac

# ==============================================================================
# 3. DETECTION AUTOMATIQUE DU CPU (INTEL OU AMD) POUR MICROCODE & TEMPERATURE
# ==============================================================================
CPU_MODEL="$(sysctl -n hw.model || true)"
CPU_VENDOR="UNKNOWN"
CPU_TEMP_MOD=""
CPU_UCODE_BIN=""

case "${CPU_MODEL}" in
    *Intel*|*INTEL*)
        CPU_VENDOR="INTEL"
        CPU_TEMP_MOD="coretemp"
        CPU_UCODE_BIN="/boot/firmware/intel-ucode.bin"
        ;;
    *AMD*|*AuthenticAMD*)
        CPU_VENDOR="AMD"
        CPU_TEMP_MOD="amdtemp"
        CPU_UCODE_BIN="/boot/firmware/amd-ucode.bin"
        ;;
esac

# ==============================================================================
# 4. DETECTION GPU ET MENU BSDDIALOG (NVIDIA 580/LATEST/470, INTEL, AMD)
# ==============================================================================
DETECTED_GPU="$(pciconf -lv | awk '
    /^vgapci/ { in_vga=1; vendor=""; device="" }
    in_vga && /vendor[[:space:]]*=/ {
        sub(/^[^'\'']*'\''/, "", $0)
        sub(/'\''.*$/, "", $0)
        vendor=$0
    }
    in_vga && /device[[:space:]]*=/ {
        sub(/^[^'\'']*'\''/, "", $0)
        sub(/'\''.*$/, "", $0)
        device=$0
        print vendor " - " device
        exit
    }
')"

if [ -z "${DETECTED_GPU}" ]; then
    DETECTED_GPU="Carte graphique non identifiee via pciconf"
fi

STATE_NV580="off"
STATE_NVLATEST="off"
STATE_NV470="off"
STATE_INTEL="off"
STATE_AMDGPU="off"
STATE_RADEON="off"

case "${DETECTED_GPU}" in
    *Intel*|*INTEL*)
        STATE_INTEL="on"
        ;;
    *AMD*|*Advanced\ Micro\ Devices*|*ATI*)
        STATE_AMDGPU="on"
        ;;
    *K[0-9][0-9][0-9]*|*GK1*|*GTX\ 6*|*GTX\ 7*)
        STATE_NV470="on"
        ;;
    *)
        STATE_NV580="on"
        ;;
esac

GPU_CHOICE="$(bsddialog --backtitle "${BACKTITLE}" \
    --title "Selection de la carte graphique et du pilote" \
    --radiolist "GPU detecte : ${DETECTED_GPU}\n\n\
Choisissez le pilote graphique correspondant a votre materiel :" 20 78 6 \
    "nvidia-580"    "NVIDIA 580 (Quadro P4000 Pascal / RTX 4000 Turing - Wayland)" "${STATE_NV580}" \
    "nvidia-latest" "NVIDIA Latest 590+ (RTX 4000 Turing / Ampere / Ada - Wayland)" "${STATE_NVLATEST}" \
    "nvidia-470"    "NVIDIA 470 Legacy (Kepler K4000 - X11 uniquement, sans DRM)" "${STATE_NV470}" \
    "intel"         "Intel Graphics (i915kms + drm-66-kmod + VA-API - Wayland)" "${STATE_INTEL}" \
    "amdgpu"        "AMD Radeon Moderne GCN/RDNA (amdgpu + drm-66-kmod - Wayland)" "${STATE_AMDGPU}" \
    "radeonkms"     "AMD ATI Radeon Legacy pre-GCN (radeonkms + drm-66-kmod)" "${STATE_RADEON}" \
    3>&1 1>&2 2>&3)" || exit 1

case "${GPU_CHOICE}" in
    nvidia-580)
        GPU_VENDOR="NVIDIA"
        GPU_USER_PKGS="nvidia-driver-580 linux-nvidia-libs-580 egl-wayland"
        GPU_KMOD_PKGS="drm-66-kmod nvidia-kmod-580 nvidia-drm-66-kmod-580"
        GPU_PORTS_LIST="graphics/drm-66-kmod x11/nvidia-kmod-580 graphics/nvidia-drm-66-kmod-580"
        GPU_KLD_MODULES="nvidia-modeset nvidia-drm"
        GPU_WAYLAND_MODE="NVIDIA_GBM"
        GPU_DESC="NVIDIA Branche 580 (Wayland + DRM-KMS)"
        ;;
    nvidia-latest)
        GPU_VENDOR="NVIDIA"
        GPU_USER_PKGS="nvidia-driver linux-nvidia-libs egl-wayland"
        GPU_KMOD_PKGS="drm-66-kmod nvidia-kmod nvidia-drm-66-kmod"
        GPU_PORTS_LIST="graphics/drm-66-kmod x11/nvidia-kmod graphics/nvidia-drm-66-kmod"
        GPU_KLD_MODULES="nvidia-modeset nvidia-drm"
        GPU_WAYLAND_MODE="NVIDIA_GBM"
        GPU_DESC="NVIDIA Branche Latest (Wayland + DRM-KMS)"
        ;;
    nvidia-470)
        GPU_VENDOR="NVIDIA"
        GPU_USER_PKGS="nvidia-driver-470 linux-nvidia-libs-470 plasma6-kwin-x11"
        GPU_KMOD_PKGS="nvidia-kmod-470"
        GPU_PORTS_LIST="x11/nvidia-kmod-470"
        GPU_KLD_MODULES="nvidia-modeset"
        GPU_WAYLAND_MODE="X11_ONLY"
        GPU_DESC="NVIDIA Branche 470 Legacy (X11 uniquement)"
        ;;
    intel)
        GPU_VENDOR="INTEL"
        GPU_USER_PKGS="mesa-libs mesa-dri libva-intel-driver libva-intel-media-driver vulkan-loader"
        GPU_KMOD_PKGS="drm-66-kmod gpu-firmware-intel-kmod"
        GPU_PORTS_LIST="graphics/drm-66-kmod graphics/gpu-firmware-intel-kmod"
        GPU_KLD_MODULES="i915kms"
        GPU_WAYLAND_MODE="MESA_NATIVE"
        GPU_DESC="Intel i915kms (Mesa + VA-API + Wayland)"
        ;;
    amdgpu)
        GPU_VENDOR="AMD"
        GPU_USER_PKGS="mesa-libs mesa-dri vulkan-loader"
        GPU_KMOD_PKGS="drm-66-kmod gpu-firmware-amd-kmod"
        GPU_PORTS_LIST="graphics/drm-66-kmod graphics/gpu-firmware-amd-kmod"
        GPU_KLD_MODULES="amdgpu"
        GPU_WAYLAND_MODE="MESA_NATIVE"
        GPU_DESC="AMD amdgpu (Mesa + Vulkan + Wayland)"
        ;;
    radeonkms)
        GPU_VENDOR="AMD"
        GPU_USER_PKGS="mesa-libs mesa-dri"
        GPU_KMOD_PKGS="drm-66-kmod gpu-firmware-radeon-kmod"
        GPU_PORTS_LIST="graphics/drm-66-kmod graphics/gpu-firmware-radeon-kmod"
        GPU_KLD_MODULES="radeonkms"
        GPU_WAYLAND_MODE="MESA_NATIVE"
        GPU_DESC="AMD Legacy radeonkms (Mesa + DRM)"
        ;;
    *)
        exit 1
        ;;
esac

# ==============================================================================
# 5. MENU BSDDIALOG POUR LA RESOLUTION D'ECRAN (PRIORITAIRE SUR L'EDID 4K)
# ==============================================================================
SCREEN_RES="$(bsddialog --backtitle "${BACKTITLE}" \
    --title "Selection de la resolution d'ecran (Prioritaire sur EDID)" \
    --radiolist "Choisissez la resolution qui sera forcee prioritairement sur la console, SDDM, Xorg et Plasma 6 (permet de forcer 2560x1440 sur un ecran 3840x2160) :" 16 76 4 \
    "1920x1080" "Full HD (16:9 - 1920x1080 - Forcee)" "on" \
    "1920x1200" "WUXGA (16:10 - 1920x1200 - Forcee)" "off" \
    "2560x1440" "QHD / 2K (16:9 - 2560x1440 - Forcee sur ecran 4K/2K)" "off" \
    "3840x2160" "UHD / 4K (16:9 - 3840x2160)" "off" \
    3>&1 1>&2 2>&3)" || exit 1

if [ -z "${SCREEN_RES}" ]; then
    SCREEN_RES="1920x1080"
fi

RES_WIDTH="${SCREEN_RES%x*}"
RES_HEIGHT="${SCREEN_RES#*x}"

# ==============================================================================
# 6. DEMANDE D'INSTALLATION DE L'ENVIRONNEMENT BUREAUTIQUE STANDARD
# ==============================================================================
INSTALL_OFFICE="NO"
OFFICE_STATUS_LABEL="Non (ignore)"
OFFICE_PKGS=""

if bsddialog --backtitle "${BACKTITLE}" \
    --title "Environnement Bureautique et Multimedia" \
    --yes-label "Oui, installer" \
    --no-label "Non, ignorer" \
    --yesno "Souhaitez-vous installer l'environnement bureautique et multimedia standard ?\n\n\
Paquets officiels FreeBSD inclus (localisation geree nativement) :\n\
- editors/libreoffice\n\
- www/firefox\n\
- mail/thunderbird\n\
- multimedia/vlc (+ multimedia/ffmpeg, libdvdread, libdvdnav, v4l_compat)" 15 76; then
    INSTALL_OFFICE="YES"
    OFFICE_STATUS_LABEL="Oui (libreoffice, firefox, thunderbird, vlc)"
    OFFICE_PKGS="libreoffice firefox thunderbird vlc ffmpeg libdvdread libdvdnav v4l_compat"
fi

# Demande de confirmation globale via bsddialog avant execution
bsddialog --backtitle "${BACKTITLE}" \
    --title "Confirmation de la configuration (v${SCRIPT_VERSION})" \
    --yesno "Les parametres suivants vont etre appliques :\n\n\
- Utilisateur cible : ${TARGET_USER} (UID : ${TARGET_UID}, classe : french)\n\
- Groupes ajoutes   : wheel, operator, video, cups\n\
- CPU detecte       : ${CPU_VENDOR} (${CPU_TEMP_MOD:-standard})\n\
- Clavier X11/Wayland : Layout='${XKB_LAYOUT}' Variant='${XKB_VARIANT}'\n\
- Locale systeme    : ${SYS_LOCALE}\n\
- GPU detecte       : ${DETECTED_GPU}\n\
- Pilote retenu     : ${GPU_DESC}\n\
- Resolution forcee : ${SCREEN_RES} (prioritaire sur l'EDID)\n\
- Theme SDDM        : nasa (telecharge depuis github.com/msartor99/FreeBSD14)\n\
- Impression/Audio  : CUPS, Gutenprint, HPLIP, Avahi (optimise SSH), PipeWire\n\
- Bureautique       : ${OFFICE_STATUS_LABEL}\n\n\
Voulez-vous lancer l'installation et la configuration (affichage detaille en console) ?" 22 78 || exit 0

clear

# ==============================================================================
# 7. ACTIVATION PREALABLE DE LINUXULATOR ET FSTAB (/proc, /dev/fd, /compat/linux)
# ==============================================================================
print_step "ETAPE 7 : Activation de Linuxulator et montage de /etc/fstab"

sysrc linux_enable="YES"
sysrc linux64_enable="YES"

mkdir -v -p /proc /dev/fd /compat/linux/dev/fd /compat/linux/dev/shm /compat/linux/proc /compat/linux/sys

if ! grep -Eq "^[^#]*[[:space:]]+/proc[[:space:]]+procfs" "${FSTAB}"; then
    printf "proc\t\t/proc\t\tprocfs\trw\t0\t0\n" >> "${FSTAB}"
    printf "[AJOUT] /proc dans %s\n" "${FSTAB}"
fi
if ! grep -Eq "^[^#]*[[:space:]]+/dev/fd[[:space:]]+fdescfs" "${FSTAB}"; then
    printf "fdesc\t\t/dev/fd\t\tfdescfs\trw\t0\t0\n" >> "${FSTAB}"
    printf "[AJOUT] /dev/fd dans %s\n" "${FSTAB}"
fi

add_line_if_missing "${FSTAB}" "devfs /compat/linux/dev devfs rw,late 0 0"
add_line_if_missing "${FSTAB}" "tmpfs /compat/linux/dev/shm tmpfs rw,late,size=1g,mode=1777 0 0"
add_line_if_missing "${FSTAB}" "fdescfs /compat/linux/dev/fd fdescfs rw,late,linrdlnk 0 0"
add_line_if_missing "${FSTAB}" "linprocfs /compat/linux/proc linprocfs rw,late 0 0"
add_line_if_missing "${FSTAB}" "linsysfs /compat/linux/sys linsysfs rw,late 0 0"

kldload -v linux || true
kldload -v linux64 || true
service linux start || true
mount -v -a || true
mount -v -al || true

# ==============================================================================
# 8. INSTALLATION DU MICROCODE CPU, DE LA BASE LINUX ET DES PAQUETS SYSTEME
# ==============================================================================
print_step "ETAPE 8 : Nettoyage des branches GPU en conflit et mise a jour pkg"

case "${GPU_CHOICE}" in
    nvidia-580)
        pkg delete -f nvidia-driver nvidia-driver-470 nvidia-kmod nvidia-kmod-470 \
            nvidia-drm-kmod nvidia-drm-61-kmod nvidia-drm-66-kmod nvidia-drm-612-kmod \
            linux-nvidia-libs linux-nvidia-libs-470 || true
        ;;
    nvidia-latest)
        pkg delete -f nvidia-driver-580 nvidia-driver-470 nvidia-kmod-580 nvidia-kmod-470 \
            nvidia-drm-61-kmod-580 nvidia-drm-66-kmod-580 nvidia-drm-612-kmod-580 \
            linux-nvidia-libs-580 linux-nvidia-libs-470 || true
        ;;
    nvidia-470)
        pkg delete -f nvidia-driver nvidia-driver-580 nvidia-kmod nvidia-kmod-580 \
            nvidia-drm-kmod nvidia-drm-61-kmod nvidia-drm-66-kmod nvidia-drm-612-kmod \
            nvidia-drm-61-kmod-580 nvidia-drm-66-kmod-580 nvidia-drm-612-kmod-580 \
            linux-nvidia-libs linux-nvidia-libs-580 || true
        ;;
    *)
        pkg delete -f nvidia-driver nvidia-driver-580 nvidia-driver-470 \
            nvidia-kmod nvidia-kmod-580 nvidia-kmod-470 \
            nvidia-drm-kmod nvidia-drm-61-kmod nvidia-drm-66-kmod nvidia-drm-612-kmod \
            nvidia-drm-61-kmod-580 nvidia-drm-66-kmod-580 nvidia-drm-612-kmod-580 \
            linux-nvidia-libs linux-nvidia-libs-580 linux-nvidia-libs-470 || true
        ;;
esac

env ASSUME_ALWAYS_YES=yes pkg update -f

print_step "ETAPE 8a : Installation et configuration du Microcode CPU (${CPU_VENDOR})"
install_verified_pkgs cpu-microcode

if [ "${CPU_VENDOR}" = "INTEL" ]; then
    remove_kv_config "${LOADER_CONF}" "amdtemp_load"
    set_kv_config "${LOADER_CONF}" "coretemp_load" '"YES"'
    set_kv_config "${LOADER_CONF}" "cpu_microcode_load" '"YES"'
    set_kv_config "${LOADER_CONF}" "cpu_microcode_name" "\"${CPU_UCODE_BIN}\""
    sysrc microcode_update_enable="YES"
elif [ "${CPU_VENDOR}" = "AMD" ]; then
    remove_kv_config "${LOADER_CONF}" "coretemp_load"
    set_kv_config "${LOADER_CONF}" "amdtemp_load" '"YES"'
    set_kv_config "${LOADER_CONF}" "cpu_microcode_load" '"YES"'
    set_kv_config "${LOADER_CONF}" "cpu_microcode_name" "\"${CPU_UCODE_BIN}\""
    sysrc microcode_update_enable="YES"
fi

print_step "ETAPE 8b : Installation de la base Linuxulator (Rocky Linux 9)"
install_verified_pkgs \
    linux_base-rl9 \
    linux-rl9-xorg-libs \
    linux-rl9-wayland

service linux restart || true

print_step "ETAPE 8c : Installation des pilotes GPU (${GPU_DESC}) et des paquets Workstation"
# shellcheck disable=SC2086
install_verified_pkgs \
    ${GPU_USER_PKGS} \
    xorg \
    xf86-input-libinput \
    wayland \
    seatd \
    libglvnd \
    dbus \
    avahi-app \
    nss_mdns \
    plasma6-plasma \
    plasma6-libkscreen \
    plasma6-plasma-pa \
    plasma6-xdg-desktop-portal-kde \
    sddm \
    consolekit2 \
    automount \
    fusefs-ntfs \
    fusefs-exfat \
    exfat-utils \
    fusefs-ext2 \
    fusefs-hfsfuse \
    cups \
    gutenprint \
    cups-filters \
    hplip \
    system-config-printer \
    pulseaudio \
    pipewire \
    wireplumber \
    pavucontrol \
    freedesktop-sound-theme \
    alsa-utils

if [ "${INSTALL_OFFICE}" = "YES" ]; then
    print_step "ETAPE 8d : Installation de l'environnement Bureautique et Multimedia"
    # shellcheck disable=SC2086
    install_verified_pkgs ${OFFICE_PKGS}
fi

print_step "ETAPE 8e : Installation des modules noyau GPU (${GPU_KMOD_PKGS})"
if [ -f "/usr/src/sys/Makefile" ] && [ -d "/usr/ports/graphics/drm-66-kmod" ]; then
    printf "Arbre /usr/src et /usr/ports detectes : compilation des kmods depuis les ports...\n"
    for _port in ${GPU_PORTS_LIST}; do
        if [ -d "/usr/ports/${_port}" ]; then
            printf "==> Compilation de /usr/ports/%s\n" "${_port}"
            (cd "/usr/ports/${_port}" && make deinstall install clean BATCH=yes)
        fi
    done
else
    printf "Installation des modules noyau binaires via pkg...\n"
    # shellcheck disable=SC2086
    install_verified_pkgs ${GPU_KMOD_PKGS}
fi

# ==============================================================================
# 9. CONFIGURATION DE LA CLASSE DE CONNEXION 'french', ADDUSER.CONF ET COMPTES
# ==============================================================================
print_step "ETAPE 9 : Configuration de /etc/login.conf, /etc/adduser.conf et des groupes"

set_kv_config "${ADDUSER_CONF}" "defaultclass" "french"

if ! grep -Eq "^french[:|]" "${LOGIN_CONF}"; then
    cat << EOF >> "${LOGIN_CONF}"

french|French Users Accounts:\\
	:charset=UTF-8:\\
	:lang=${SYS_LOCALE}:\\
	:tc=default:
EOF
    printf "[AJOUT] Classe 'french' ajoutee dans %s\n" "${LOGIN_CONF}"
else
    sed -i '' "/^french[:|]/,/^[^[:space:]]/ s/:lang=[^:]*:/:lang=${SYS_LOCALE}:/" "${LOGIN_CONF}"
    sed -i '' "/^french[:|]/,/^[^[:space:]]/ s/:charset=[^:]*:/:charset=UTF-8:/" "${LOGIN_CONF}"
    printf "[MAJ] Classe 'french' mise a jour avec %s dans %s\n" "${SYS_LOCALE}" "${LOGIN_CONF}"
fi

if ! grep -Fq "lang=${SYS_LOCALE}" "${LOGIN_CONF}"; then
    if grep -Fq ":charset=" "${LOGIN_CONF}"; then
        sed -i '' "s/:charset=[^:]*:/:charset=UTF-8:/" "${LOGIN_CONF}"
    fi
    if grep -Fq ":lang=" "${LOGIN_CONF}"; then
        sed -i '' "s/:lang=[^:]*:/:lang=${SYS_LOCALE}:/" "${LOGIN_CONF}"
    else
        sed -i '' "/^default:\\\\/a\\
	:charset=UTF-8:\\\\
	:lang=${SYS_LOCALE}:\\\\
" "${LOGIN_CONF}"
    fi
fi

cap_mkdb -v "${LOGIN_CONF}"

pw usermod "${TARGET_USER}" -G wheel,operator,video,cups -L french
pw usermod root -L french
id "${TARGET_USER}"

# ==============================================================================
# 10. CONFIGURATION /boot/loader.conf ET /etc/rc.conf
# ==============================================================================
print_step "ETAPE 10 : Configuration de /boot/loader.conf et /etc/rc.conf"

set_kv_config "${LOADER_CONF}" "boot_mute" '"YES"'
set_kv_config "${LOADER_CONF}" "autoboot_delay" '"3"'
set_kv_config "${LOADER_CONF}" "tmpfs_load" '"YES"'
set_kv_config "${LOADER_CONF}" "sound_load" '"YES"'
set_kv_config "${LOADER_CONF}" "snd_hda_load" '"YES"'
set_kv_config "${LOADER_CONF}" "fusefs_load" '"YES"'
set_kv_config "${LOADER_CONF}" "efi_max_resolution" "\"${SCREEN_RES}\""
set_kv_config "${LOADER_CONF}" "kern.vt.fb.default_mode" "\"${SCREEN_RES}\""

if [ "${GPU_WAYLAND_MODE}" = "NVIDIA_GBM" ]; then
    set_kv_config "${LOADER_CONF}" "hw.nvidiadrm.modeset" '"1"'
    set_kv_config "${LOADER_CONF}" "hw.nvidiadrm.fbdev" '"0"'
    set_kv_config "${LOADER_CONF}" "compat.linuxkpi.skb.mem_limit" '"1"'
elif [ "${GPU_VENDOR}" = "INTEL" ] || [ "${GPU_VENDOR}" = "AMD" ]; then
    remove_kv_config "${LOADER_CONF}" "hw.nvidiadrm.modeset"
    remove_kv_config "${LOADER_CONF}" "hw.nvidiadrm.fbdev"
    set_kv_config "${LOADER_CONF}" "compat.linuxkpi.skb.mem_limit" '"1"'
else
    remove_kv_config "${LOADER_CONF}" "hw.nvidiadrm.modeset"
    remove_kv_config "${LOADER_CONF}" "hw.nvidiadrm.fbdev"
fi

if [ -n "${CPU_TEMP_MOD}" ]; then
    sysrc kld_list="linux linux64 fusefs ext2fs snd_hda ${CPU_TEMP_MOD} ${GPU_KLD_MODULES}"
else
    sysrc kld_list="linux linux64 fusefs ext2fs snd_hda ${GPU_KLD_MODULES}"
fi

sysrc rc_startmsgs="NO"
sysrc dbus_enable="YES"
sysrc avahi_daemon_enable="YES"
sysrc seatd_enable="YES"
sysrc cupsd_enable="YES"
sysrc devfs_system_ruleset="localrules"
sysrc sddm_enable="YES"

# ==============================================================================
# 11. OPTIMISATIONS /etc/sysctl.conf, AUTOMOUNT USB ET DEVFS ([localrules=5])
# ==============================================================================
print_step "ETAPE 11 : Configuration de /etc/sysctl.conf, Automount USB et /etc/devfs.rules"

kldload -v fusefs || true
kldload -v ext2fs || true
kldload -v tmpfs || true

set_kv_config "${SYSCTL_CONF}" "kern.sched.preempt_thresh" "224"
set_kv_config "${SYSCTL_CONF}" "kern.ipc.shm_allow_removed" "1"
set_kv_config "${SYSCTL_CONF}" "net.local.stream.recvspace" "65536"
set_kv_config "${SYSCTL_CONF}" "net.local.stream.sendspace" "65536"
set_kv_config "${SYSCTL_CONF}" "vfs.usermount" "1"

mkdir -v -p /media
chown root:operator /media
chmod 0775 /media

cat << 'EOF' > "${DEVFS_RULES}"
[localrules=5]
add path 'da*' mode 0660 group operator
add path 'ada*' mode 0660 group operator
add path 'cd*' mode 0660 group operator
add path 'mmcsd*' mode 0660 group operator
add path 'uscanner*' mode 0660 group operator
add path 'xpt*' mode 0660 group operator
add path 'pass*' mode 0660 group operator
add path 'md*' mode 0660 group operator
add path 'fuse*' mode 0660 group operator
add path 'msdosfs/*' mode 0660 group operator
add path 'ext2fs/*' mode 0660 group operator
add path 'ntfs/*' mode 0660 group operator
add path 'usb/*' mode 0660 group operator
add path 'ugen*' mode 0660 group operator
add path 'video*' mode 0660 group operator
add path 'dri/*' mode 0660 group video
add path 'drm/*' mode 0660 group video
add path 'unlpt*' mode 0660 group cups
add path 'lpt*' mode 0660 group cups
add path 'ulpt*' mode 0660 group cups
EOF
printf "[ECRITURE] %s configure avec [localrules=5]\n" "${DEVFS_RULES}"

cat << EOF > /usr/local/etc/automount.conf
USERUMOUNT=YES
ATIME=NO
REMOVEDIRS=YES
FM="dolphin"
USER="${TARGET_USER}"
ENCODING="${SYS_LOCALE}"
CODEPAGE="cp850"
EOF
printf "[ECRITURE] /usr/local/etc/automount.conf configure pour %s\n" "${TARGET_USER}"

# ==============================================================================
# 12. CONFIGURATION IMPRIMANTES RESEAU, AVAHI ET ANTI-LATENCE SSH/PUTTY
# ==============================================================================
print_step "ETAPE 12 : Optimisation reseau Avahi / mDNS / SSH (anti-latence PuTTY) et CUPS"

if [ -f "${NSSWITCH_CONF}" ]; then
    sed -i '' 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns/' "${NSSWITCH_CONF}"
    grep "^hosts:" "${NSSWITCH_CONF}"
fi

if [ -f "${AVAHI_CONF}" ]; then
    sed -i '' 's/^[#[:space:]]*use-ipv6=.*/use-ipv6=no/' "${AVAHI_CONF}"
    sed -i '' 's/^[#[:space:]]*publish-aaaa-on-ipv4=.*/publish-aaaa-on-ipv4=no/' "${AVAHI_CONF}"
    printf "[MAJ] IPv6 desactive dans %s\n" "${AVAHI_CONF}"
fi

if [ -f "${SSHD_CONF}" ]; then
    if grep -Eq "^[#[:space:]]*UseDNS" "${SSHD_CONF}"; then
        sed -i '' 's/^[#[:space:]]*UseDNS.*/UseDNS no/' "${SSHD_CONF}"
    else
        printf "\nUseDNS no\n" >> "${SSHD_CONF}"
    fi
    printf "[MAJ] UseDNS no applique dans %s\n" "${SSHD_CONF}"
    service sshd reload || true
fi

service devfs restart || true
service devd restart || true
service dbus restart || true
service avahi-daemon restart || true
service cupsd restart || true

# ==============================================================================
# 13. CONFIGURATION AUDIO (PIPEWIRE / PULSEAUDIO / SORTIE PAR DEFAUT)
# ==============================================================================
print_step "ETAPE 13 : Configuration Audio et rechargement sysctl"

kldload -v snd_hda || true
set_kv_config "${SYSCTL_CONF}" "hw.snd.verbose" "0"
set_kv_config "${LOADER_CONF}" "hint.hdac.0.cad0.nid5.config" '"as=1 seq=0"'

DEFAULT_AUDIO_UNIT="1"
if [ -r "/dev/sndstat" ]; then
    cat /dev/sndstat
    DETECTED_PCM=""
    case "${GPU_VENDOR}" in
        NVIDIA)
            DETECTED_PCM="$(awk '/^pcm[0-9]+: <NVIDIA/ { sub(/^pcm/, "", $1); sub(/:$/, "", $1); print $1; exit }' /dev/sndstat)"
            ;;
        AMD)
            DETECTED_PCM="$(awk '/^pcm[0-9]+: <(ATI|AMD)/ { sub(/^pcm/, "", $1); sub(/:$/, "", $1); print $1; exit }' /dev/sndstat)"
            ;;
        INTEL)
            DETECTED_PCM="$(awk '/^pcm[0-9]+: <Intel.*HDMI|DisplayPort/ { sub(/^pcm/, "", $1); sub(/:$/, "", $1); print $1; exit }' /dev/sndstat)"
            ;;
    esac
    if [ -n "${DETECTED_PCM}" ]; then
        DEFAULT_AUDIO_UNIT="${DETECTED_PCM}"
    fi
fi

set_kv_config "${SYSCTL_CONF}" "hw.snd.default_unit" "${DEFAULT_AUDIO_UNIT}"
sysctl "hw.snd.default_unit=${DEFAULT_AUDIO_UNIT}" || true

service sysctl reload

# ==============================================================================
# 14. CONFIGURATION CLAVIER, RESOLUTION PRIORITAIRE, THEME SDDM 'nasa' & PLASMA 6
# ==============================================================================
print_step "ETAPE 14 : Configuration Xorg, Resolution ${SCREEN_RES}, Theme SDDM 'nasa' et Plasma 6"

mkdir -v -p /usr/local/etc/X11/xorg.conf.d
rm -f /usr/local/etc/X11/xorg.conf.d/20-keyboard.conf

cat << EOF > /usr/local/etc/X11/xorg.conf.d/20-keyboards.conf
Section "ServerFlags"
    Option "DontZap" "false"
EndSection

Section "InputClass"
    Identifier      "All Keyboards"
    MatchIsKeyboard "yes"
    Option          "XkbModel" "pc105"
    Option          "XkbLayout" "${XKB_LAYOUT}"
    Option          "XkbVariant" "${XKB_VARIANT}"
    Option          "XkbOptions" "terminate:ctrl_alt_bksp"
EndSection
EOF

cat << EOF > /usr/local/etc/X11/xorg.conf.d/30-monitor.conf
Section "Monitor"
    Identifier "DefaultMonitor"
    Option     "PreferredMode" "${SCREEN_RES}"
EndSection

Section "Screen"
    Identifier "DefaultScreen"
    Monitor    "DefaultMonitor"
    Option     "MetaModes" "${SCREEN_RES} +0+0"
    SubSection "Display"
        Virtual ${RES_WIDTH} ${RES_HEIGHT}
        Modes   "${SCREEN_RES}"
    EndSubSection
EndSection
EOF

if [ "${GPU_CHOICE}" = "nvidia-470" ]; then
    cat << 'EOF' > /usr/local/etc/X11/xorg.conf.d/20-nvidia.conf
Section "Device"
    Identifier "NVIDIA Card"
    Driver "nvidia"
EndSection
EOF
else
    rm -f /usr/local/etc/X11/xorg.conf.d/20-nvidia.conf
fi

# 14a. Creation et personnalisation du theme SDDM 'nasa' (base sur 'maldives')
printf "==> Preparation du theme SDDM 'nasa' dans %s...\n" "${NASA_THEME_DIR}"
mkdir -v -p "${NASA_THEME_DIR}"
if [ -d "${SDDM_THEMES_DIR}/maldives" ]; then
    cp -v -R "${SDDM_THEMES_DIR}/maldives/"* "${NASA_THEME_DIR}/"
fi

rm -v -f "${NASA_THEME_DIR}/Main.qml" \
         "${NASA_THEME_DIR}/main.qml" \
         "${NASA_THEME_DIR}/metadata.desktop" \
         "${NASA_THEME_DIR}/"*.png \
         "${NASA_THEME_DIR}/"*.jpg

for _sddm_file in Main.qml metadata.desktop nasa2560login.png nasa1920.png; do
    printf "Telechargement de %s...\n" "${_sddm_file}"
    fetch -o "${NASA_THEME_DIR}/${_sddm_file}" "${GITHUB_RAW_BASE}/${_sddm_file}"
done

chmod -v 0644 "${NASA_THEME_DIR}/Main.qml" \
              "${NASA_THEME_DIR}/metadata.desktop" \
              "${NASA_THEME_DIR}/nasa2560login.png" \
              "${NASA_THEME_DIR}/nasa1920.png"

# 14b. Script centralise d'application prioritaire de la resolution (SDDM, X11 et Wayland)
cat << EOF > /usr/local/bin/apply-workstation-resolution.sh
#!/bin/sh
TARGET_RES="${SCREEN_RES}"
TARGET_W="${RES_WIDTH}"
TARGET_H="${RES_HEIGHT}"

if [ -n "\${WAYLAND_DISPLAY:-}" ] || [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    if command -v kscreen-doctor >/dev/null 2>&1; then
        sleep 1
        _outputs="\$(kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | awk '/Output:/ {print \$3}')"
        for _out in \${_outputs}; do
            _mode_id="\$(kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | awk -v out="\${_out}" -v res="\${TARGET_RES}" '
                \$1 == "Output:" && \$3 == out { in_out=1; next }
                \$1 == "Output:" && \$3 != out { in_out=0 }
                in_out && /Modes:/ {
                    for (i=1; i<=NF; i++) {
                        if (\$i ~ ":" res "@") {
                            split(\$i, a, ":")
                            print a[1]
                            exit
                        }
                    }
                }
            ')"
            if [ -n "\${_mode_id}" ]; then
                kscreen-doctor "output.\${_out}.mode.\${_mode_id}" "output.\${_out}.scale.1" || true
            else
                kscreen-doctor "output.\${_out}.mode.\${TARGET_RES}@60" "output.\${_out}.scale.1" || \
                kscreen-doctor "output.\${_out}.mode.\${TARGET_RES}" "output.\${_out}.scale.1" || true
            fi
        done
        exit 0
    fi
fi

if command -v xrandr >/dev/null 2>&1; then
    for _out in \$(xrandr --query | awk '/ connected/ {print \$1}'); do
        if ! xrandr --output "\${_out}" --mode "\${TARGET_RES}" --scale 1x1; then
            if command -v cvt >/dev/null 2>&1; then
                _modeline="\$(cvt "\${TARGET_W}" "\${TARGET_H}" 60 | awk '/Modeline/ { \$1=""; \$2=""; print \$0 }')"
                xrandr --newmode "\${TARGET_RES}_60" \${_modeline} || true
                xrandr --addmode "\${_out}" "\${TARGET_RES}_60" || true
                xrandr --output "\${_out}" --mode "\${TARGET_RES}_60" --scale 1x1 || true
            fi
        fi
    done
fi
EOF
chmod -v 0755 /usr/local/bin/apply-workstation-resolution.sh

# 14c. Configuration SDDM avec le theme 'nasa' par defaut et Xsetup
mkdir -v -p /usr/local/etc/sddm.conf.d /usr/local/etc/sddm/scripts
cat << 'EOF' > /usr/local/etc/sddm/scripts/Xsetup
#!/bin/sh
/usr/local/bin/apply-workstation-resolution.sh
EOF
chmod -v 0755 /usr/local/etc/sddm/scripts/Xsetup

cat << 'EOF' > /usr/local/etc/sddm.conf.d/10-freebsd-workstation.conf
[General]
DisplayServer=x11
NumLock=on

[Theme]
Current=nasa

[Wayland]
SessionDir=/usr/local/share/wayland-sessions

[X11]
SessionDir=/usr/local/share/xsessions
DisplayCommand=/usr/local/etc/sddm/scripts/Xsetup
EOF

mkdir -v -p /usr/local/etc/xdg/autostart
cat << 'EOF' > /usr/local/etc/xdg/autostart/00-set-resolution.desktop
[Desktop Entry]
Type=Application
Name=Force Operator Screen Resolution
Exec=/usr/local/bin/apply-workstation-resolution.sh
X-KDE-AutostartPhase=0
X-KDE-StartupNotify=false
NoDisplay=true
EOF

mkdir -v -p /usr/local/etc/xdg/plasma-workspace/env
rm -f /usr/local/etc/xdg/plasma-workspace/env/nvidia-wayland.sh
rm -f /usr/local/etc/xdg/plasma-workspace/env/nvidia-session.sh

if [ "${GPU_WAYLAND_MODE}" = "NVIDIA_GBM" ]; then
    cat << EOF > /usr/local/etc/xdg/plasma-workspace/env/gpu-session.sh
#!/bin/sh
export LANG="${SYS_LOCALE}"
export MM_CHARSET="UTF-8"
export GBM_BACKEND="nvidia-drm"
export __GLX_VENDOR_LIBRARY_NAME="nvidia"
export KWIN_DRM_USE_EGL_STREAMS="0"
export QT_QPA_PLATFORM="wayland;xcb"
export MOZ_ENABLE_WAYLAND="1"
export XKB_DEFAULT_MODEL="pc105"
export XKB_DEFAULT_LAYOUT="${XKB_LAYOUT}"
export XKB_DEFAULT_VARIANT="${XKB_VARIANT}"
EOF
elif [ "${GPU_WAYLAND_MODE}" = "MESA_NATIVE" ]; then
    cat << EOF > /usr/local/etc/xdg/plasma-workspace/env/gpu-session.sh
#!/bin/sh
export LANG="${SYS_LOCALE}"
export MM_CHARSET="UTF-8"
export QT_QPA_PLATFORM="wayland;xcb"
export MOZ_ENABLE_WAYLAND="1"
export XKB_DEFAULT_MODEL="pc105"
export XKB_DEFAULT_LAYOUT="${XKB_LAYOUT}"
export XKB_DEFAULT_VARIANT="${XKB_VARIANT}"
EOF
else
    cat << EOF > /usr/local/etc/xdg/plasma-workspace/env/gpu-session.sh
#!/bin/sh
export LANG="${SYS_LOCALE}"
export MM_CHARSET="UTF-8"
export __GLX_VENDOR_LIBRARY_NAME="nvidia"
export QT_QPA_PLATFORM="xcb"
export XKB_DEFAULT_MODEL="pc105"
export XKB_DEFAULT_LAYOUT="${XKB_LAYOUT}"
export XKB_DEFAULT_VARIANT="${XKB_VARIANT}"
EOF
fi
chmod -v 0755 /usr/local/etc/xdg/plasma-workspace/env/gpu-session.sh

mkdir -v -p /usr/local/etc/xdg
cat << EOF > /usr/local/etc/xdg/kxkbrc
[Layout]
DisplayNames=
LayoutList=${XKB_LAYOUT}
Model=pc105
ResetOldOptions=true
Use=true
VariantList=${XKB_VARIANT}
EOF

cat << EOF > /usr/local/etc/xdg/plasma-localerc
[Formats]
LANG=${SYS_LOCALE}
EOF

USER_HOME="$(pw user show "${TARGET_USER}" | awk -F: '{print $9}')"
if [ -d "${USER_HOME}" ]; then
    mkdir -v -p "${USER_HOME}/.config"
    cp -v /usr/local/etc/xdg/kxkbrc "${USER_HOME}/.config/kxkbrc"
    cp -v /usr/local/etc/xdg/plasma-localerc "${USER_HOME}/.config/plasma-localerc"
    rm -v -rf "${USER_HOME}/.local/share/kscreen"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.config"
fi

printf "\n==============================================================================\n"
printf "==> INSTALLATION TERMINEE AVEC SUCCES (v%s)\n" "${SCRIPT_VERSION}"
printf "==============================================================================\n"

# ==============================================================================
# 15. FIN D'INSTALLATION ET PROPOSITION DE REDEMARRAGE VIA BSDDIALOG
# ==============================================================================
if bsddialog --backtitle "${BACKTITLE}" \
    --title "Installation terminee (v${SCRIPT_VERSION})" \
    --yesno "La configuration de la workstation FreeBSD 16 est terminee :\n\n\
- Createur / Superviseur : Gemini / ${SUPERVISOR_EMAIL}\n\
- Utilisateur configure  : ${TARGET_USER} (UID ${TARGET_UID}, classe : french)\n\
- CPU detecte            : ${CPU_VENDOR} (${CPU_TEMP_MOD:-standard})\n\
- GPU detecte            : ${DETECTED_GPU}\n\
- Pilote installe        : ${GPU_DESC}\n\
- Resolution forcee      : ${SCREEN_RES} (prioritaire sur l'EDID)\n\
- Theme SDDM actif       : nasa\n\
- Clavier XKB / Plasma   : ${XKB_LAYOUT} (${XKB_VARIANT:-standard})\n\
- Locale appliquee       : ${SYS_LOCALE}\n\
- Impression & Audio     : CUPS/Gutenprint/HPLIP + Avahi (sans latence SSH)\n\
- Bureautique            : ${OFFICE_STATUS_LABEL}\n\n\
Voulez-vous redemarrer le systeme maintenant ?" 22 76; then
    shutdown -r now
fi