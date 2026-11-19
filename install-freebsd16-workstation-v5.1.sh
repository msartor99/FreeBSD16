#!/bin/sh
# ==============================================================================
# Script Name : install-freebsd16-workstation-v5.1.sh
# Version     : 5.1 (X11 & Plasma 6 LTS / Wayland Edition - FreeBSD 16 / 15)
# Description : Idempotent FreeBSD 16 Workstation Installer
#               (Plasma 6 LTS X11 + Plasma 6 Wayland + XFCE + MATE + VBox 7.2)
# Author      : Created by Gemini & supervised by msartor99@gmail.com
# Standards   : Strict POSIX /bin/sh, Native BSD utilities, Idempotent
# ==============================================================================

set -eu

SCRIPT_VERSION="5.1"
SUPERVISOR_EMAIL="msartor99@gmail.com"

# ------------------------------------------------------------------------------
# 0. Root Privilege & Dependencies Check
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	printf "ERROR: This script must be run as root.\n" >&2
	exit 1
fi

if ! command -v bsddialog >/dev/null 2>&1; then
	printf "ERROR: bsddialog is required but not found in base system.\n" >&2
	exit 1
fi

# ------------------------------------------------------------------------------
# Helper Functions for Idempotency
# ------------------------------------------------------------------------------
append_if_missing() {
	_line="$1"
	_file="$2"
	touch "${_file}"
	if ! grep -Fqx "${_line}" "${_file}"; then
		printf "%s\n" "${_line}" >> "${_file}"
	fi
}

set_sysctl_conf() {
	_key="$1"
	_val="$2"
	touch /etc/sysctl.conf
	if grep -Eq "^[[:space:]]*${_key}=" /etc/sysctl.conf; then
		sed -i '' "s|^[[:space:]]*${_key}=.*|${_key}=${_val}|" /etc/sysctl.conf
	else
		printf "%s=%s\n" "${_key}" "${_val}" >> /etc/sysctl.conf
	fi
}

set_loader_conf() {
	_key="$1"
	_val="$2"
	touch /boot/loader.conf
	case "${_key}" in
		*.*)
			if grep -Eq "^[[:space:]]*${_key}=" /boot/loader.conf; then
				sed -i '' "s|^[[:space:]]*${_key}=.*|${_key}=\"${_val}\"|" /boot/loader.conf
			else
				printf "%s=\"%s\"\n" "${_key}" "${_val}" >> /boot/loader.conf
			fi
			;;
		*)
			sysrc -f /boot/loader.conf "${_key}=${_val}"
			;;
	esac
}

add_kld_list() {
	_mod="$1"
	_current="$(sysrc -n kld_list 2>/dev/null || true)"
	case " ${_current} " in
		*" ${_mod} "*) ;;
		*)
			if [ -z "${_current}" ]; then
				sysrc kld_list="${_mod}" >/dev/null
			else
				sysrc kld_list="${_current} ${_mod}" >/dev/null
			fi
			;;
	esac
}

remove_kld_list() {
	_mod="$1"
	_current="$(sysrc -n kld_list 2>/dev/null || true)"
	_new=""
	for _item in ${_current}; do
		if [ "${_item}" != "${_mod}" ]; then
			_new="${_new:+${_new} }${_item}"
		fi
	done
	sysrc kld_list="${_new}" >/dev/null
}

pkg_install_safe() {
	for _pkg in "$@"; do
		if pkg info -e "${_pkg}" >/dev/null 2>&1; then
			printf "[OK] Package '%s' is already installed.\n" "${_pkg}"
		elif pkg rquery "%n" "${_pkg}" >/dev/null 2>&1; then
			printf "[INSTALL] Installing '%s'...\n" "${_pkg}"
			pkg install -y "${_pkg}"
		else
			printf "[WARN] Package '%s' not found in current repository, skipping.\n" "${_pkg}"
		fi
	done
}

detect_screen_resolution() {
	_res=""
	_res="$(sysctl -a 2>/dev/null | sed -n 's/^kern\.vt\.fb\.modes\..*: \([0-9]\{3,4\}x[0-9]\{3,4\}\).*$/\1/p' | head -n 1 || true)"
	if [ -z "${_res}" ]; then
		_res="$(dmesg 2>/dev/null | sed -n 's/^.*VT.*resolution \([0-9]\{3,4\}x[0-9]\{3,4\}\).*$/\1/p' | tail -n 1 || true)"
	fi
	if [ -z "${_res}" ] && command -v xrandr >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
		_res="$(xrandr --current 2>/dev/null | awk '/\*/ {print $1; exit}' || true)"
	fi
	if [ -z "${_res}" ] && [ -f /var/log/Xorg.0.log ]; then
		_res="$(sed -n 's/^.*Modeline "\([0-9]\{3,4\}x[0-9]\{3,4\}\).*$/\1/p' /var/log/Xorg.0.log 2>/dev/null | head -n 1 || true)"
	fi
	printf "%s" "${_res}"
}

# ------------------------------------------------------------------------------
# 1. Operator Disclaimer (bsddialog Yes / No)
# ------------------------------------------------------------------------------
DISCLAIMER_TEXT="FreeBSD 16 Workstation Automated Installer (v${SCRIPT_VERSION})

This script was created by Gemini and supervised by ${SUPERVISOR_EMAIL}.

It will configure and install in an idempotent manner:
 - OS Branch & PKG repository verification (RELEASE: latest vs quarterly)
 - Base system tuning, SSH, CPU microcode, Linux binary compatibility (RL9)
 - Auto-detection of user, keyboard layout, base locale & monitor resolution
 - CUPS printing, FUSE filesystems, PipeWire / PulseAudio sound stack
 - Xorg (X11), GPU drivers, SDDM with custom NASA theme & boot splash
 - Desktop Environments: KDE Plasma 6 LTS (X11), Plasma 6 (Wayland), MATE, XFCE
 - Optional VirtualBox 7.2 installation

Do you accept the terms and wish to proceed with the installation?"

if ! bsddialog --backtitle "FreeBSD 16 Workstation Installer v${SCRIPT_VERSION}" \
	--title "Disclaimer & Operator Approval" \
	--yesno "${DISCLAIMER_TEXT}" 21 78; then
	clear
	printf "Installation cancelled by operator.\n"
	exit 0
fi

# ------------------------------------------------------------------------------
# 2. Verify FreeBSD Branch (RELEASE vs CURRENT/STABLE) & Repository Selection
# ------------------------------------------------------------------------------
FBSD_BRANCH="$(uname -r)"
PKG_REPO_MODE="latest (Default for ${FBSD_BRANCH})"

case "${FBSD_BRANCH}" in
	*RELEASE*)
		if bsddialog --backtitle "FreeBSD 16 Workstation Installer v${SCRIPT_VERSION}" \
			--title "Package Repository Branch (${FBSD_BRANCH})" \
			--yesno "Detected FreeBSD RELEASE version: ${FBSD_BRANCH}\n\nBy default, RELEASE versions use the 'quarterly' package branch.\nDo you want to switch the package repositories to 'latest'?\n\n - Select YES to switch to 'latest'\n - Select NO to keep/use 'quarterly'" 14 74; then
			PKG_REPO_MODE="latest"
		else
			PKG_REPO_MODE="quarterly"
		fi
		;;
	*)
		PKG_REPO_MODE="latest (Native CURRENT/STABLE)"
		;;
esac

# ------------------------------------------------------------------------------
# 3. Detect Target Operator User (First user with UID >= 1000)
# ------------------------------------------------------------------------------
TARGET_USER="$(awk -F: '$3 == 1000 && $1 != "nobody" { print $1; exit }' /etc/passwd)"
if [ -z "${TARGET_USER}" ]; then
	TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody" { print $1; exit }' /etc/passwd | head -n 1)"
fi

if [ -z "${TARGET_USER}" ]; then
	bsddialog --title "User Detection Error" \
		--msgbox "No standard user with UID >= 1000 was found in /etc/passwd.\nPlease create a user first." 8 65
	exit 1
fi

# ------------------------------------------------------------------------------
# 4. Detect Keyboard, Locale (Defaulting Swiss to fr_CH) & Monitor Resolution
# ------------------------------------------------------------------------------
RAW_KEYMAP="$(sysrc -n keymap 2>/dev/null || printf "ch.fr.kbd")"
RAW_KEYMAP="${RAW_KEYMAP%.kbd}"

XKB_LAYOUT="ch"
XKB_VARIANT="fr"

case "${RAW_KEYMAP}" in
	swissgerman*|ch.de*|de_CH*)
		XKB_LAYOUT="ch"
		XKB_VARIANT="de"
		;;
	swissfrench*|ch.fr*|fr_CH*|ch*|sf*)
		XKB_LAYOUT="ch"
		XKB_VARIANT="fr"
		;;
	fr*.acc*|fr.macbook*)
		XKB_LAYOUT="fr"
		XKB_VARIANT="oss"
		;;
	fr*)
		XKB_LAYOUT="fr"
		XKB_VARIANT=""
		;;
	be*)
		XKB_LAYOUT="be"
		XKB_VARIANT=""
		;;
	de*)
		XKB_LAYOUT="de"
		XKB_VARIANT=""
		;;
	uk*|gb*)
		XKB_LAYOUT="gb"
		XKB_VARIANT=""
		;;
	us*|default|"")
		XKB_LAYOUT="us"
		XKB_VARIANT=""
		;;
	*)
		XKB_LAYOUT="ch"
		XKB_VARIANT="fr"
		;;
esac

SYS_LANG="${LANG:-}"
if [ -z "${SYS_LANG}" ] || [ "${SYS_LANG}" = "C" ] || [ "${SYS_LANG}" = "C.UTF-8" ] || [ "${SYS_LANG}" = "de_CH.UTF-8" ]; then
	case "${XKB_LAYOUT}_${XKB_VARIANT}" in
		ch_de) SYS_LANG="de_CH.UTF-8" ;;
		ch_*)  SYS_LANG="fr_CH.UTF-8" ;;
		fr_*)  SYS_LANG="fr_FR.UTF-8" ;;
		be_*)  SYS_LANG="fr_BE.UTF-8" ;;
		de_*)  SYS_LANG="de_DE.UTF-8" ;;
		*)     SYS_LANG="fr_CH.UTF-8" ;;
	esac
fi
SDDM_LANG="${SYS_LANG%.*}"

DETECTED_RES="$(detect_screen_resolution)"
if [ -n "${DETECTED_RES}" ]; then
	RES_HEIGHT="${DETECTED_RES#*x}"
	case "${RES_HEIGHT}" in
		2160) EFI_RES="2160p" ;;
		1440) EFI_RES="1440p" ;;
		1080) EFI_RES="1080p" ;;
		720)  EFI_RES="720p"  ;;
		*)    EFI_RES="max"   ;;
	esac
	RES_SUMMARY="${DETECTED_RES} (EFI: ${EFI_RES})"
else
	EFI_RES="max"
	RES_SUMMARY="Auto/EDID (EFI: max)"
fi

# ------------------------------------------------------------------------------
# 5. GPU Driver Selection Menu via bsddialog
# ------------------------------------------------------------------------------
DETECTED_GPU="$(pciconf -lv 2>/dev/null | awk '/^vgapci/ {flag=1} flag && /device/ {gsub(/^[[:space:]]+/, ""); print; flag=0}' | head -n 1 || true)"
if [ -z "${DETECTED_GPU}" ]; then
	DETECTED_GPU="Unknown VGA Controller"
fi

GPU_CHOICE="$(bsddialog --backtitle "FreeBSD 16 Workstation Installer v${SCRIPT_VERSION}" \
	--title "Graphics Driver Selection" \
	--menu "OS: ${FBSD_BRANCH} (${PKG_REPO_MODE}) | User: ${TARGET_USER}\nKeymap: ${RAW_KEYMAP} -> X11: ${XKB_LAYOUT}/${XKB_VARIANT} | Locale: ${SYS_LANG} | Res: ${RES_SUMMARY}\nDetected GPU: ${DETECTED_GPU}\n\nSelect the graphics driver to install:" 18 78 4 \
	"A1" "NVIDIA Latest (Quadro RTX 4000, GeForce RTX 3060 & newer)" \
	"A2" "NVIDIA Branch 580 (Quadro P2000, P4000 & Pascal generation)" \
	"B"  "AMD Radeon (RX 550 Polaris / amdgpu drm-kmod)" \
	"C"  "Hybrid Intel + NVIDIA PRIME (Notebook / HP Z2 Mini)" \
	3>&1 1>&2 2>&3)" || {
	clear
	printf "GPU selection cancelled by operator.\n"
	exit 0
}

# ------------------------------------------------------------------------------
# 6. Desktop Environment Selection Menu via bsddialog
# ------------------------------------------------------------------------------
RAW_DE_CHOICES="$(bsddialog --backtitle "FreeBSD 16 Workstation Installer v${SCRIPT_VERSION}" \
	--title "Desktop Environment Selection" \
	--checklist "Use SPACE to select Desktop Environments (Note: Choose either PLASMA6LTS for X11 or PLASMA6 for Wayland, not both):" 15 78 4 \
	"PLASMA6LTS" "KDE Plasma 6.6 LTS (Native X11 session via plasma6lts-kwin-x11)" on \
	"PLASMA6"    "KDE Plasma 6.8+ (Wayland session via seatd + Xwayland)" off \
	"XFCE"       "XFCE 4 Desktop Environment (xfce + xfce4-goodies)" on \
	"MATE"       "MATE Desktop Environment" on \
	3>&1 1>&2 2>&3)" || {
	clear
	printf "Desktop Environment selection cancelled by operator.\n"
	exit 0
}

DE_CHOICES="$(printf "%s" "${RAW_DE_CHOICES}" | tr -d '"')"

# Prevent conflicting installation if operator selected both PLASMA6LTS and PLASMA6
case " ${DE_CHOICES} " in
	*" PLASMA6LTS "*)
		case " ${DE_CHOICES} " in
			*" PLASMA6 "*)
				bsddialog --title "Plasma Branch Conflict Notice" \
					--msgbox "Both PLASMA6LTS (X11) and PLASMA6 (Wayland) were selected.\nSince they conflict, PLASMA6LTS (X11) will be prioritized." 8 68
				_cleaned_de=""
				for _d in ${DE_CHOICES}; do
					if [ "${_d}" != "PLASMA6" ]; then
						_cleaned_de="${_cleaned_de:+${_cleaned_de} }${_d}"
					fi
				done
				DE_CHOICES="${_cleaned_de}"
				;;
		esac
		;;
esac

if [ -z "${DE_CHOICES}" ]; then
	bsddialog --title "Warning" \
		--msgbox "No Desktop Environment was selected. Only Xorg and SDDM will be installed." 7 65
fi

# ------------------------------------------------------------------------------
# 7. Boot Splash Screen Selection via bsddialog
# ------------------------------------------------------------------------------
SPLASH_CHOICE="$(bsddialog --backtitle "FreeBSD 16 Workstation Installer v${SCRIPT_VERSION}" \
	--title "Boot Splash Theme Selection" \
	--menu "Choose the boot splash image:" 11 65 2 \
	"V2BLUE" "Kamila v2-blue (v2-blue1080.png)" \
	"NASA"   "NASA 1920x1080 (nasa1920.png)" \
	3>&1 1>&2 2>&3)" || {
	clear
	printf "Splash selection cancelled by operator.\n"
	exit 0
}

# ------------------------------------------------------------------------------
# 8. VirtualBox 7.2 Installation Prompt (bsddialog Yes / No)
# ------------------------------------------------------------------------------
INSTALL_VBOX="NO"
if bsddialog --backtitle "FreeBSD 16 Workstation Installer v${SCRIPT_VERSION}" \
	--title "VirtualBox 7.2 Installation" \
	--yesno "Do you want to install Oracle VM VirtualBox 7.2 (virtualbox-ose-72), configure kernel modules, and grant '${TARGET_USER}' vboxusers permissions?" 9 72; then
	INSTALL_VBOX="YES"
fi

clear
printf "====================================================================\n"
printf "Starting FreeBSD Workstation Configuration (v%s)\n" "${SCRIPT_VERSION}"
printf "OS Version    : %s\n" "${FBSD_BRANCH}"
printf "PKG Repo Mode : %s\n" "${PKG_REPO_MODE}"
printf "Target User   : %s\n" "${TARGET_USER}"
printf "Keymap/X11    : %s -> layout='%s' variant='%s'\n" "${RAW_KEYMAP}" "${XKB_LAYOUT}" "${XKB_VARIANT}"
printf "Base Locale   : %s (SDDM: %s)\n" "${SYS_LANG}" "${SDDM_LANG}"
printf "Screen Res.   : %s\n" "${RES_SUMMARY}"
printf "GPU Option    : %s\n" "${GPU_CHOICE}"
printf "Desktop Env.  : %s\n" "${DE_CHOICES:-None}"
printf "VirtualBox 7.2: %s\n" "${INSTALL_VBOX}"
printf "====================================================================\n\n"

# ------------------------------------------------------------------------------
# 9. Configure Package Repositories & Sudo / Doas
# ------------------------------------------------------------------------------
mkdir -p /usr/local/etc/pkg/repos

case "${FBSD_BRANCH}" in
	*RELEASE*)
		if grep -Fq "FreeBSD-ports:" /etc/pkg/FreeBSD.conf 2>/dev/null; then
			if [ "${PKG_REPO_MODE}" = "latest" ]; then
				cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOF'
FreeBSD-ports: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/latest"
}
FreeBSD-ports-kmods: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/kmods_latest_${VERSION_MINOR}"
}
EOF
			else
				cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOF'
FreeBSD-ports: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/quarterly"
}
FreeBSD-ports-kmods: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/kmods_quarterly_${VERSION_MINOR}"
}
EOF
			fi
		else
			cat > /usr/local/etc/pkg/repos/FreeBSD.conf << EOF
FreeBSD: {
  url: "pkg+https://pkg.FreeBSD.org/\${ABI}/${PKG_REPO_MODE}"
}
EOF
		fi
		;;
	*)
		rm -f /usr/local/etc/pkg/repos/FreeBSD.conf
		;;
esac

pkg update -f
pkg_install_safe sudo doas

if [ ! -f /usr/local/etc/doas.conf ]; then
	cat > /usr/local/etc/doas.conf << 'EOF'
permit persist :wheel
permit nopass root as root
EOF
	chmod 0600 /usr/local/etc/doas.conf
fi

# ------------------------------------------------------------------------------
# 10. Base Configuration & SSH
# ------------------------------------------------------------------------------
sysrc sshd_enable="YES"

if grep -Eq "^[[:space:]#]*PermitRootLogin" /etc/ssh/sshd_config; then
	sed -i '' 's/^[[:space:]#]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
	printf "PermitRootLogin yes\n" >> /etc/ssh/sshd_config
fi
service sshd restart || service sshd start || true

case "${FBSD_BRANCH}" in
	*RELEASE*)
		if ! pkg info -e FreeBSD-runtime >/dev/null 2>&1; then
			PAGER=/bin/cat freebsd-update --not-running-from-cron fetch install || true
		fi
		;;
	*)
		printf "[INFO] Non-RELEASE branch detected (%s): skipping freebsd-update.\n" "${FBSD_BRANCH}"
		;;
esac

# ------------------------------------------------------------------------------
# 11. Boot Loader (Dynamic Screen Resolution) & Sysctl Tuning
# ------------------------------------------------------------------------------
set_loader_conf "boot_mute" "YES"
set_loader_conf "autoboot_delay" "3"
set_loader_conf "tmpfs_load" "YES"
set_loader_conf "efi_max_resolution" "${EFI_RES}"

if [ -n "${DETECTED_RES}" ]; then
	set_loader_conf "kern.vt.fb.default_mode" "${DETECTED_RES}"
else
	if [ -f /boot/loader.conf ]; then
		sed -i '' '/^[[:space:]]*kern\.vt\.fb\.default_mode=/d' /boot/loader.conf
	fi
fi

sysrc background_dhclient="YES"
sysrc rc_startmsgs="NO"

set_sysctl_conf "kern.sched.preempt_thresh" "224"
set_sysctl_conf "kern.ipc.shm_allow_removed" "1"
set_sysctl_conf "net.local.stream.recvspace" "65536"
set_sysctl_conf "net.local.stream.sendspace" "65536"
set_sysctl_conf "vfs.usermount" "1"

service sysctl reload

# ------------------------------------------------------------------------------
# 12. Configure User Locale Class (Idempotent & Updates Existing Entry)
# ------------------------------------------------------------------------------
if grep -Fq "workstation_locale|Workstation Locale Accounts:" /etc/login.conf; then
	sed -i '' "s/:lang=.*:/:lang=${SYS_LANG}:/g" /etc/login.conf
	sed -i '' "s/:setenv=LC_ALL=.*:/:setenv=LC_ALL=${SYS_LANG},LC_COLLATE=${SYS_LANG},LC_CTYPE=${SYS_LANG},LC_MESSAGES=${SYS_LANG}:/g" /etc/login.conf
else
	cat >> /etc/login.conf << EOF

workstation_locale|Workstation Locale Accounts:\\
	:charset=UTF-8:\\
	:lang=${SYS_LANG}:\\
	:setenv=LC_ALL=${SYS_LANG},LC_COLLATE=${SYS_LANG},LC_CTYPE=${SYS_LANG},LC_MESSAGES=${SYS_LANG}:\\
	:tc=default:
EOF
fi
cap_mkdb /etc/login.conf

printf "defaultclass=workstation_locale\n" > /etc/adduser.conf
pw usermod "${TARGET_USER}" -L workstation_locale
pw usermod root -L workstation_locale

for _grp in wheel operator video; do
	pw groupmod "${_grp}" -m "${TARGET_USER}" 2>/dev/null || true
done

# ------------------------------------------------------------------------------
# 13. CPU Microcode & Thermal Sensor (Auto-detected Intel / AMD)
# ------------------------------------------------------------------------------
pkg_install_safe cpu-microcode
CPU_MODEL="$(sysctl -n hw.model 2>/dev/null || true)"

case "${CPU_MODEL}" in
	*Intel*|*INTEL*)
		printf "[CPU] Intel processor detected (%s)\n" "${CPU_MODEL}"
		set_loader_conf "coretemp_load" "YES"
		set_loader_conf "cpu_microcode_load" "YES"
		set_loader_conf "cpu_microcode_name" "/boot/firmware/intel-ucode.bin"
		;;
	*AMD*|*AuthenticAMD*)
		printf "[CPU] AMD processor detected (%s)\n" "${CPU_MODEL}"
		set_loader_conf "amdtemp_load" "YES"
		set_loader_conf "cpu_microcode_load" "YES"
		set_loader_conf "cpu_microcode_name" "/boot/firmware/amd-ucode.bin"
		;;
	*)
		printf "[CPU] Generic processor (%s): enabling microcode_update service only.\n" "${CPU_MODEL}"
		;;
esac
sysrc microcode_update_enable="YES"

# ------------------------------------------------------------------------------
# 14. Linux Binary Compatibility (Rocky Linux 9)
# ------------------------------------------------------------------------------
sysrc linux_enable="YES"
sysrc linux_mounts_enable="YES"
service linux start || true
pkg_install_safe linux-rl9

# ------------------------------------------------------------------------------
# 15. Base Utilities & S.M.A.R.T. Disk Monitoring
# ------------------------------------------------------------------------------
pkg_install_safe unzip libzip wget git htop btop fastfetch python3 ImageMagick7 smartmontools

if [ ! -f /usr/local/etc/smartd.conf ] && [ -f /usr/local/etc/smartd.conf.sample ]; then
	cp /usr/local/etc/smartd.conf.sample /usr/local/etc/smartd.conf
fi
sysrc smartd_enable="YES"
service smartd restart || service smartd start || true

# ------------------------------------------------------------------------------
# 16. Printer Manager (CUPS), FUSE & Filesystems Support
# ------------------------------------------------------------------------------
pkg_install_safe cups gutenprint cups-filters hplip system-config-printer
pkg_install_safe fusefs-ntfs fusefs-ext2 fusefs-hfsfuse

add_kld_list "fusefs"
add_kld_list "ext2fs"
kldload -n fusefs 2>/dev/null || true
kldload -n ext2fs 2>/dev/null || true

pw groupmod cups -m "${TARGET_USER}" 2>/dev/null || true

sysrc cupsd_enable="YES"
service cupsd restart || service cupsd start || true

# ------------------------------------------------------------------------------
# 17. Audio Configuration
# ------------------------------------------------------------------------------
pkg_install_safe pulseaudio pipewire wireplumber pavucontrol freedesktop-sound-theme

set_loader_conf "sound_load" "YES"
set_loader_conf "snd_hda_load" "YES"

set_sysctl_conf "hw.snd.default_unit" "1"
sysctl hw.snd.default_unit=1 >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 18. Xorg (Pure X11), Fonts & Mounts
# ------------------------------------------------------------------------------
pkg_install_safe xorg dbus avahi consolekit2 montserrat noto-basic

sysrc dbus_enable="YES"
sysrc avahi_daemon_enable="YES"
service dbus restart || service dbus start || true
service avahi-daemon restart || service avahi-daemon start || true

if ! grep -Eq "^[[:space:]]*proc[[:space:]]+/proc[[:space:]]+procfs" /etc/fstab; then
	printf "proc\t\t/proc\t\tprocfs\trw\t0\t0\n" >> /etc/fstab
fi
if ! grep -Eq "^[[:space:]]*fdesc[[:space:]]+/dev/fd[[:space:]]+fdescfs" /etc/fstab; then
	printf "fdesc\t\t/dev/fd\t\tfdescfs\trw\t0\t0\n" >> /etc/fstab
fi
mount -a || true

# ------------------------------------------------------------------------------
# 19. X11 Keyboard Configuration
# ------------------------------------------------------------------------------
mkdir -p /usr/local/etc/X11/xorg.conf.d

if [ -n "${XKB_VARIANT}" ]; then
	VARIANT_LINE="    Option          \"XkbVariant\" \"${XKB_VARIANT}\""
else
	VARIANT_LINE="    # No XkbVariant required for ${XKB_LAYOUT}"
fi

cat > /usr/local/etc/X11/xorg.conf.d/20-keyboards.conf << EOF
Section "ServerFlags"
    Option "DontZap" "false"
EndSection

Section "InputClass"
    Identifier      "All Keyboards"
    MatchIsKeyboard "yes"
    Option          "XkbLayout" "${XKB_LAYOUT}"
${VARIANT_LINE}
    Option          "XkbOptions" "terminate:ctrl_alt_bksp"
EndSection
EOF

# ------------------------------------------------------------------------------
# 20. Install Selected Graphics Driver (Auto-Resizing via EDID)
# ------------------------------------------------------------------------------
rm -f /usr/local/etc/X11/xorg.conf.d/10-amdgpu.conf
rm -f /usr/local/etc/X11/xorg.conf.d/10-nvidia.conf
remove_kld_list "nvidia-modeset"
remove_kld_list "amdgpu"
remove_kld_list "i915kms"

case "${GPU_CHOICE}" in
	A1)
		pkg_install_safe nvidia-driver nvidia-kmod linux-nvidia-libs libc6-shim nvidia-settings nvidia-xconfig
		pkg_install_safe libva-vdpau-driver libva-utils
		add_kld_list "nvidia-modeset"
		cat > /usr/local/etc/X11/xorg.conf.d/10-nvidia.conf << 'EOF'
Section "Device"
    Identifier     "NVIDIA Card"
    Driver         "nvidia"
    Option         "ModeValidation" "NoMaxResolutionCheck"
EndSection
EOF
		;;
	A2)
		pkg_install_safe nvidia-driver-580 nvidia-kmod-580 linux-nvidia-libs-580 libc6-shim nvidia-settings nvidia-xconfig
		pkg_install_safe libva-vdpau-driver libva-utils
		add_kld_list "nvidia-modeset"
		cat > /usr/local/etc/X11/xorg.conf.d/10-nvidia.conf << 'EOF'
Section "Device"
    Identifier     "NVIDIA Card"
    Driver         "nvidia"
    Option         "ModeValidation" "NoMaxResolutionCheck"
EndSection
EOF
		;;
	B)
		pkg_install_safe drm-kmod gpu-firmware-kmod xf86-video-amdgpu
		pkg_install_safe mesa-gallium-va mesa-gallium-vdpau libva-utils
		add_kld_list "amdgpu"
		cat > /usr/local/etc/X11/xorg.conf.d/10-amdgpu.conf << 'EOF'
Section "Device"
    Identifier     "AMD Radeon GPU"
    Driver         "amdgpu"
    Option         "TearFree" "true"
EndSection
EOF
		;;
	C)
		pkg_install_safe drm-kmod gpu-firmware-kmod nvidia-driver nvidia-kmod nvidia-settings
		pkg_install_safe libva-intel-media-driver libva-vdpau-driver libva-utils
		add_kld_list "i915kms"
		add_kld_list "nvidia-modeset"
		;;
esac

# ------------------------------------------------------------------------------
# 21. Install SDDM, Custom NASA Theme & Boot Splash
# ------------------------------------------------------------------------------
pkg_install_safe sddm

sysrc sddm_enable="YES"
sysrc sddm_lang="${SDDM_LANG}"

if [ -f /usr/local/share/sddm/scripts/Xsetup ]; then
	sed -i '' '/^setxkbmap /d' /usr/local/share/sddm/scripts/Xsetup
	if [ -n "${XKB_VARIANT}" ]; then
		printf "setxkbmap %s %s\n" "${XKB_LAYOUT}" "${XKB_VARIANT}" >> /usr/local/share/sddm/scripts/Xsetup
	else
		printf "setxkbmap %s\n" "${XKB_LAYOUT}" >> /usr/local/share/sddm/scripts/Xsetup
	fi
fi

if [ ! -d /tmp/fb14_assets ]; then
	git clone https://github.com/msartor99/FreeBSD14 /tmp/fb14_assets
else
	git -C /tmp/fb14_assets pull --ff-only || true
fi

if [ -d /usr/local/share/sddm/themes/maldives ]; then
	mkdir -p /usr/local/share/sddm/themes/nasa
	cp -R /usr/local/share/sddm/themes/maldives/* /usr/local/share/sddm/themes/nasa/
	rm -f /usr/local/share/sddm/themes/nasa/*.jpg
	cp /tmp/fb14_assets/nasa2560login.jpg /usr/local/share/sddm/themes/nasa/background.jpg
fi

cat > /usr/local/etc/sddm.conf << 'EOF'
[General]
InputMethod=
displayFont="Montserrat"

[Theme]
Current=nasa
background=background.jpg
EOF

mkdir -p /boot/images
if [ "${SPLASH_CHOICE}" = "NASA" ]; then
	cp /tmp/fb14_assets/nasa1920.png /boot/images/splash.png
else
	cp /tmp/fb14_assets/v2-blue1080.png /boot/images/splash.png
fi

set_loader_conf "splash_changer_enable" "YES"
set_loader_conf "splash" "/boot/images/splash.png"
set_loader_conf "shutdown_splash" "/boot/images/splash.png"

# ------------------------------------------------------------------------------
# 22. Install Selected Desktop Environments (XFCE, MATE, PLASMA6LTS, PLASMA6)
# ------------------------------------------------------------------------------
case " ${DE_CHOICES} " in
	*" XFCE "*)
		printf "[DE] Installing XFCE 4 Desktop Environment...\n"
		pkg_install_safe xfce xfce4-goodies
		;;
esac

case " ${DE_CHOICES} " in
	*" MATE "*)
		printf "[DE] Installing MATE Desktop Environment...\n"
		pkg_install_safe mate
		;;
esac

case " ${DE_CHOICES} " in
	*" PLASMA6LTS "*)
		printf "[DE] Installing KDE Plasma 6.6 LTS (Native X11 Edition)...\n"
		# Remove any broken plasmax11.desktop pointing to startplasma-wayland
		if [ -f /usr/local/share/xsessions/plasmax11.desktop ] && grep -Fq "startplasma-wayland" /usr/local/share/xsessions/plasmax11.desktop; then
			rm -f /usr/local/share/xsessions/plasmax11.desktop
		fi

		pkg_install_safe plasma6lts-plasma
		pkg_install_safe plasma6lts-plasma-workspace plasma6lts-plasma-desktop \
			plasma6lts-kwin plasma6lts-kwin-x11 \
			plasma6lts-systemsettings plasma6lts-sddm-kcm plasma6lts-kdeplasma-addons \
			plasma6lts-breeze plasma6lts-layer-shell-qt plasma6lts-kscreen
		pkg_install_safe pavucontrol kate konsole ark remmina dolphin

		# Ensure X11 session file exists if startplasma-x11 binary is installed
		if [ -x /usr/local/bin/startplasma-x11 ] && [ ! -f /usr/local/share/xsessions/plasmax11.desktop ] && [ ! -f /usr/local/share/xsessions/plasma.desktop ]; then
			mkdir -p /usr/local/share/xsessions
			cat > /usr/local/share/xsessions/plasmax11.desktop << 'EOF'
[Desktop Entry]
Type=XSession
Exec=/usr/local/bin/ck-launch-session /usr/local/bin/dbus-run-session /usr/local/bin/startplasma-x11
TryExec=/usr/local/bin/startplasma-x11
DesktopNames=KDE
Name=Plasma 6 LTS (X11)
Comment=Plasma 6 LTS by KDE (X11)
EOF
		fi
		;;
esac

case " ${DE_CHOICES} " in
	*" PLASMA6 "*)
		printf "[DE] Installing KDE Plasma 6.8+ (Wayland Edition + seatd + Xwayland)...\n"
		# Remove any invalid XSession wrapper calling startplasma-wayland
		if [ -f /usr/local/share/xsessions/plasmax11.desktop ] && grep -Fq "startplasma-wayland" /usr/local/share/xsessions/plasmax11.desktop; then
			rm -f /usr/local/share/xsessions/plasmax11.desktop
		fi

		pkg_install_safe seatd xwayland
		sysrc seatd_enable="YES"
		pw groupmod seatd -m "${TARGET_USER}" 2>/dev/null || true
		service seatd restart || service seatd start || true

		pkg_install_safe plasma6-plasma kde
		pkg_install_safe plasma6-plasma-workspace plasma6-plasma-desktop \
			plasma6-kwin plasma6-systemsettings plasma6-sddm-kcm \
			plasma6-kdeplasma-addons plasma6-breeze plasma6-layer-shell-qt plasma6-kscreen
		pkg_install_safe pavucontrol kate konsole ark remmina dolphin
		;;
esac

# ------------------------------------------------------------------------------
# 23. Install Multimedia & Base Applications
# ------------------------------------------------------------------------------
pkg_install_safe firefox signal-cli xdg-user-dirs octopkg
pkg_install_safe vlc mpv ffmpeg
pkg_install_safe gstreamer1-plugins-all gstreamer1-libav libbluray libdvdread libdvdnav

# ------------------------------------------------------------------------------
# 24. Silent Boot Messages in /etc/rc (Idempotent)
# ------------------------------------------------------------------------------
if ! grep -Fq 'run_rc_script ${_rc_elem} ${_boot} > /dev/null' /etc/rc; then
	sed -i '' 's|run_rc_script ${_rc_elem} ${_boot}|run_rc_script ${_rc_elem} ${_boot} > /dev/null|g' /etc/rc
fi

# ------------------------------------------------------------------------------
# 25. Unified Devfs Ruleset & Optional VirtualBox 7.2 Installation
# ------------------------------------------------------------------------------
cat > /etc/devfs.rules << 'EOF'
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
add path 'ulpt*' mode 0660 group cups
EOF

if [ "${INSTALL_VBOX}" = "YES" ]; then
	printf "[VBOX] Installing VirtualBox 7.2...\n"
	pkg_install_safe virtualbox-ose-72 virtualbox-ose-kmod-72

	set_loader_conf "vboxdrv_load" "YES"
	sysrc vboxnet_enable="YES"

	kldload -n vboxdrv 2>/dev/null || true
	service vboxnet restart || service vboxnet start || true

	pw groupmod vboxusers -m root 2>/dev/null || true
	pw groupmod vboxusers -m "${TARGET_USER}" 2>/dev/null || true

	append_if_missing "add path 'vboxnetctl' mode 0660 group vboxusers" /etc/devfs.rules
fi

sysrc devfs_system_ruleset="localrules"
service devfs restart

# ------------------------------------------------------------------------------
# 26. Final Completion Dialog
# ------------------------------------------------------------------------------
bsddialog --backtitle "FreeBSD 16 Workstation Installer v${SCRIPT_VERSION}" \
	--title "Installation Complete" \
	--msgbox "FreeBSD Workstation configuration completed successfully!\n\nOS Version        : ${FBSD_BRANCH}\nPKG Repository    : ${PKG_REPO_MODE}\nConfigured user   : ${TARGET_USER}\nKeyboard layout   : ${XKB_LAYOUT} ${XKB_VARIANT}\nSystem locale     : ${SYS_LANG}\nScreen resolution : ${RES_SUMMARY}\nGPU Driver        : Option ${GPU_CHOICE}\nDesktops          : ${DE_CHOICES:-None}\nVirtualBox 7.2    : ${INSTALL_VBOX}\n\nPlease reboot the system to load all kernel modules and start SDDM." 19 76

clear
printf "Installation complete. Run 'shutdown -r now' to reboot.\n"