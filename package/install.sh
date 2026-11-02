#!/bin/bash
# CP-300 for the BeagleV-Fire: installer.
#
# Installs the web side (daemon, page, link on the stock web server, Cockpit sidebar entry) and flashes the CP-300
# gateware. Run it again to upgrade, or to bring the CP-300 back after another gateware was flashed: the software and
# the sidebar entry are replaced, the gateware is flashed only when it is not the one already loaded.
#
#   sudo ./install.sh               install / upgrade (asks before flashing)
#   sudo ./install.sh --yes         do not ask (you accept DISCLAIMER.txt)
#   sudo ./install.sh --no-flash    software only
#   sudo ./install.sh --force-flash flash the gateware even if it is already loaded
#   sudo ./install.sh --no-web      gateware only
#   sudo ./install.sh --uninstall   remove the software and the sidebar entry [--purge: also the disks and ROMs]
#   ./install.sh --check            report what is installed and loaded, change nothing
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)
VERSION=$(cat "$SELF/VERSION")
GATEWARE_ID=$(cat "$SELF/GATEWARE_ID")

OPT=/opt/cp300
DATA=/var/lib/cp300
GW_ROOT=/usr/share/beagleboard/gateware
GW_DIR=$GW_ROOT/cp300
CHANGE_GW=$GW_ROOT/change-gateware.sh
NGINX_SITE=/etc/nginx/sites-enabled/default
NGINX_BACKUP=/etc/nginx/cp300-default-site.backup     # not in sites-enabled: nginx loads everything in there
HOST=$OPT/syn/beaglev-fire/host

YES=0
FLASH=auto          # auto: only when the loaded gateware differs
WEB=1
ACTION=install
PURGE=0

say() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for a in "$@"; do
	case "$a" in
	--yes|-y) YES=1 ;;
	--no-flash) FLASH=no ;;
	--force-flash) FLASH=force ;;
	--no-web) WEB=0 ;;
	--uninstall) ACTION=uninstall ;;
	--purge) PURGE=1 ;;
	--check) ACTION=check ;;
	-h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option $a (see --help)" ;;
	esac
done

loaded_id() {
	if [ -r /proc/device-tree/chosen/overlays/CP300-GATEWARE ]; then
		tr -d '\0' < /proc/device-tree/chosen/overlays/CP300-GATEWARE
	fi
}

installed_version() {
	if [ -r "$OPT/VERSION" ]; then cat "$OPT/VERSION"; fi
}

check() {
	echo "package:            $VERSION (gateware $GATEWARE_ID)"
	local v; v=$(installed_version)
	echo "software installed: ${v:-none}"
	local g; g=$(loaded_id)
	echo "gateware loaded:    ${g:-not the CP-300 gateware}"
	if [ -r /sys/class/uio/uio0/name ]; then echo "uio0:               $(cat /sys/class/uio/uio0/name)"; fi
	if systemctl is-active --quiet cp300d 2>/dev/null; then echo "daemon:             running"; else echo "daemon:             not running"; fi
	if [ "$g" = "$GATEWARE_ID" ]; then echo "-> the gateware would not be flashed"; else echo "-> the gateware would be flashed (the board reboots)"; fi
}

if [ "$ACTION" = check ]; then
	check
	exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E "$0" "$@"
fi

preflight() {
	[ "$(uname -m)" = riscv64 ] || die "this package is for the BeagleV-Fire (riscv64), this machine is $(uname -m)"
	for f in VERSION GATEWARE_ID DISCLAIMER.txt gateware/LinuxProgramming/mpfs_bitstream.spi gateware/LinuxProgramming/mpfs_dtbo.spi \
		syn/beaglev-fire/host/cp300d.py tools/dsk2dmk.py deploy/cp300d.service deploy/cp300.nginx.conf; do
		[ -e "$SELF/$f" ] || die "the package is incomplete: $f is missing"
	done
	if [ "$WEB" = 1 ]; then
		command -v systemctl >/dev/null || die "systemd not found"
		command -v python3 >/dev/null || die "python3 not found"
		command -v nginx >/dev/null || die "nginx not found: the stock BeagleV-Fire image has it (sudo apt install nginx)"
		[ -f "$NGINX_SITE" ] || die "$NGINX_SITE not found: the stock web server configuration was changed"
		if ! command -v gcc >/dev/null; then
			say "installing gcc (the register access helper is built on the board)"
			apt-get install -y gcc libc6-dev
		fi
	fi
	if [ "$FLASH" != no ]; then
		[ -x "$CHANGE_GW" ] || die "$CHANGE_GW not found: install the board's gateware package (sudo apt install bbb.io-gateware)"
	fi
}

install_gateware_files() {
	say "Putting the CP-300 gateware in $GW_DIR"
	rm -rf "$GW_DIR"
	mkdir -p "$GW_DIR"
	cp -r "$SELF/gateware/LinuxProgramming" "$GW_DIR/"
	cp "$SELF/GATEWARE_ID" "$GW_DIR/"
	cp "$SELF/DISCLAIMER.txt" "$GW_DIR/"
}

install_web() {
	say "Installing the CP-300 software $VERSION in $OPT"
	mkdir -p "$OPT" "$DATA"
	rm -rf "$OPT/syn" "$OPT/tools"
	mkdir -p "$OPT/syn/beaglev-fire"
	cp -r "$SELF/syn/beaglev-fire/host" "$OPT/syn/beaglev-fire/"
	cp -r "$SELF/syn/beaglev-fire/alice" "$OPT/syn/beaglev-fire/" 2>/dev/null || true
	cp -r "$SELF/tools" "$OPT/"
	find "$OPT" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	chown -R root:root "$OPT"
	gcc -O2 -shared -fPIC -o "$HOST/regs32.so" "$HOST/regs32.c"
	# the Alice's emulator (without it the Alice machine does not start; the other machines do not need it)
	if [ -f "$OPT/syn/beaglev-fire/alice/emu/alice_emu.c" ]; then
		mkdir -p "$OPT/syn/beaglev-fire/alice/emu/build"
		gcc -O2 -std=gnu99 -o "$OPT/syn/beaglev-fire/alice/emu/build/alice_emu" "$OPT/syn/beaglev-fire/alice/emu/alice_emu.c" "$OPT/syn/beaglev-fire/alice/emu/mc6803.c" || echo "alice_emu did not compile: the Alice machine is not available"
	fi
	echo "$VERSION" > "$OPT/VERSION"

	say "UIO permissions, service, web server link, Cockpit sidebar entry"
	echo 'SUBSYSTEM=="uio", GROUP="kmem", MODE="0660"' > /etc/udev/rules.d/99-cp300-uio.rules
	udevadm control --reload
	udevadm trigger --subsystem-match=uio || true

	install -m 644 "$SELF/deploy/cp300d.service" /etc/systemd/system/cp300d.service

	install -m 644 "$SELF/deploy/cp300.nginx.conf" /etc/nginx/snippets/cp300.conf
	# 0.1.0 left its backup inside sites-enabled, which nginx loads (duplicate default server): remove it
	rm -f "$NGINX_SITE.cp300-backup"
	if ! grep -q "snippets/cp300.conf" "$NGINX_SITE"; then
		[ -e "$NGINX_BACKUP" ] || cp -L "$NGINX_SITE" "$NGINX_BACKUP"
		sed -i --follow-symlinks '0,/^[[:space:]]*server_name .*;/s//&\n\tinclude snippets\/cp300.conf;/' "$NGINX_SITE"
		grep -q "snippets/cp300.conf" "$NGINX_SITE" || die "could not add the CP-300 link to $NGINX_SITE"
	fi
	nginx -t
	systemctl reload nginx

	# the sidebar entry is replaced on every run
	rm -rf /usr/share/cockpit/cp300
	mkdir -p /usr/share/cockpit/cp300
	cp "$SELF"/deploy/cockpit/* /usr/share/cockpit/cp300/

	install -m 755 "$SELF/cp300-load-gateware" /usr/local/sbin/cp300-load-gateware

	systemctl daemon-reload
	systemctl enable cp300d >/dev/null 2>&1
	systemctl restart cp300d || true     # does nothing while another gateware is loaded (the unit has conditions)
}

flash() {
	local cur; cur=$(loaded_id)
	if [ "$FLASH" = auto ] && [ "$cur" = "$GATEWARE_ID" ]; then
		say "The CP-300 gateware ($cur) is already loaded: not flashing (--force-flash flashes it anyway)"
		return 0
	fi
	echo
	cat "$SELF/DISCLAIMER.txt"
	cat <<E

This writes the CP-300 gateware ($GATEWARE_ID) to the board's flash: the FPGA bitstream, the device tree overlay and
the Hart Software Services bootloader. The board reboots by itself and reprograms the FPGA while it starts: this takes
a couple of minutes, do not power it off before it is back.
E
	if [ "$YES" = 1 ]; then
		say "--yes given: you accept the DISCLAIMER above"
	else
		read -r -p "Type I ACCEPT to accept the disclaimer and flash, anything else to skip: " ans
		[ "$ans" = "I ACCEPT" ] || { say "Not flashed. Later: sudo cp300-load-gateware"; return 0; }
	fi
	say "Flashing"
	"$CHANGE_GW" "$GW_DIR"
}

uninstall() {
	say "Removing the CP-300 software and the sidebar entry"
	systemctl disable --now cp300d 2>/dev/null || true
	rm -f /etc/systemd/system/cp300d.service /etc/udev/rules.d/99-cp300-uio.rules /usr/local/sbin/cp300-load-gateware
	systemctl daemon-reload
	if [ -f "$NGINX_SITE" ]; then sed -i --follow-symlinks '/snippets\/cp300.conf/d' "$NGINX_SITE"; fi
	rm -f "$NGINX_SITE.cp300-backup" "$NGINX_BACKUP"
	rm -f /etc/nginx/snippets/cp300.conf
	nginx -t && systemctl reload nginx || true
	rm -rf /usr/share/cockpit/cp300 "$OPT" "$GW_DIR"
	if [ "$PURGE" = 1 ]; then rm -rf "$DATA"; else say "Disks and ROMs are kept in $DATA (--purge removes them)"; fi
	say "The CP-300 gateware stays in the FPGA until another one is flashed, e.g.: sudo $CHANGE_GW default"
}

if [ "$ACTION" = uninstall ]; then
	uninstall
	exit 0
fi

preflight
install_gateware_files
if [ "$WEB" = 1 ]; then install_web; fi
if [ "$FLASH" != no ]; then flash; fi
say "Done. CP-300: http://$(hostname)/cp300/  (also in the Cockpit sidebar). Upload the two ROMs on the page the first time."
