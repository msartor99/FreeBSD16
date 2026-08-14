# FreeBSD16

The boot mode on ZFS double M2 NVMe does not seem to work but UFS work.

# GOOD NEWS

The AQ107 card in the Lenovo P620 seems to be recognized now by the aquantia-atlantic driver on FreeBSD-16.0-CURRENT-amd64-20260810-e004ff15f87e-287922-memstick.img

The configuration appears to be correct.

# post install script

Here's the new FreeBSD 16 in its current (beta) version. The speed of this distribution is incredible; you can really see the difference compared to FreeBSD 15.1. I've adapted my post-installation script; here's the latest version:

Have fun!

fetch https://raw.githubusercontent.com/msartor99/FreeBSD16/refs/heads/main/FB16-install_universal-5.sh
