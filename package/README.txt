CP-300 for the BeagleV-Fire
===========================

The Prologica CP-300 (the Brazilian TRS-80 Model III compatible, 1983) running in the FPGA of a BeagleV-Fire.
The board has no video output and no keyboard port for the FPGA, so your browser is the monitor, keyboard, speaker
and disk drives: the board serves a web page, the CP-300 runs in the fabric.

This package installs the software on the board and flashes the CP-300 gateware (the FPGA design).

*** DISCLAIMER - USE AT YOUR OWN RISK *** (full text: DISCLAIMER.txt)
Installing this flashes the board's gateware flash, including the bootloader. A failed or interrupted flash, a power
loss, a defect or incompatibility can leave the BeagleV-Fire unable to start ("bricked"), and recovering it may need
a FlashPro5/6 programmer or may not be possible. The software is provided "as is", without warranty. The author and
contributors accept no responsibility or liability for any damage to your board or equipment, loss of data, or any
other loss. You flash entirely at your own risk. The installer shows DISCLAIMER.txt and asks you to type "I ACCEPT"
before it flashes.


1. Before you start
-------------------

You need
  - a BeagleV-Fire running the BeagleBoard.org Ubuntu image, on your network, with SSH and sudo for the user
    "beagle". (Tested: Ubuntu 24.04 image of 2025-07-21, kernel 6.6.75, stock gateware 2025.10-13.)
  - the two ROM images of the machine. They are copyrighted and are NOT in this package:
        system ROM            16384 bytes   (the CP-300 one: 27C128cp300.BIN)
        character generator    2048 bytes   (2716cp300.BIN, or the shared CHARGEN.BIN)
  - disk images of what you want to run: .dsk .dmk .hfe .jv1 .jv3 (for example a TRSDOS 1.3 disk to boot).
  - a modern browser on the same network. Sound needs one click on the page; nothing else to install.

WARNING - read before the first install
  Installing flashes the board: the FPGA bitstream, the device tree overlay and the bootloader (HSS) are rewritten.
  The board's own update mechanism keeps no fallback copy. If the board does not come back, the way out is the
  recovery in BeagleBoard's flashing guide, which needs a FlashPro5/6 programmer:
  https://docs.beagleboard.org/boards/beaglev/fire/demos-and-tutorials/flashing-board.html
  The gateware was built with an unofficial Libero SoC version (2026.1) and has been tried on one board. Do not
  install it on a board you cannot afford to recover. The installer asks before it flashes.


2. Install
----------

Copy the package to the board and unpack it, as the user "beagle":

    scp cp300-beaglev-fire-<version>.tar.gz beagle@<board>:
    ssh beagle@<board>
    tar xzf cp300-beaglev-fire-<version>.tar.gz
    cd cp300-beaglev-fire-<version>

Look first, change nothing:

    ./install.sh --check

It shows the version of this package, what is installed, which gateware is loaded and whether the daemon runs.

Install:

    sudo ./install.sh

What it does, in this order
  - puts the CP-300 gateware files in /usr/share/beagleboard/gateware/cp300,
  - installs the software in /opt/cp300 and starts it at boot (service "cp300d"); disks and ROMs live in
    /var/lib/cp300,
  - adds the CP-300 to the stock web server: http://<board>/cp300/  (a snippet in /etc/nginx/snippets, included
    from the default site; the original is saved in /etc/nginx/cp300-default-site.backup),
  - adds a CP-300 entry to the Cockpit sidebar (Tools > CP-300), https://<board>:9090,
  - shows DISCLAIMER.txt and asks you to type  I ACCEPT  to flash (anything else skips the flashing). The board
    then reboots by itself and reprograms the FPGA while it starts. This takes a couple of minutes. DO NOT POWER THE BOARD OFF until it is back (your SSH
    session ends at the reboot; ping the board or reconnect after a few minutes).
    If the CP-300 gateware is already the loaded one, it says so and does not flash again.
    Upgrading from 0.2.0: this package has a new gateware (2025.10-13-g943f37f-4302-CP300: the disk request now reaches
    the daemon as an interrupt), so the installer flashes it. With --no-flash the new software still works on the 0.2.0
    gateware; it polls instead.

Options
    sudo ./install.sh --yes            do not ask before flashing (you accept DISCLAIMER.txt by using it)
    sudo ./install.sh --no-flash       software only (flash later with: sudo cp300-load-gateware)
    sudo ./install.sh --no-web         gateware only
    sudo ./install.sh --force-flash    flash even if the CP-300 gateware is already loaded
    ./install.sh --check               report only
    sudo ./install.sh --uninstall      remove the software and the sidebar entry (--purge: also disks and ROMs)


3. First use
------------

Open  http://<board>/cp300/  in your browser (or Cockpit > Tools > CP-300 > "Open the CP-300").

  a. Load the ROMs once: in the ROMs panel choose the system ROM and the character generator. They are stored on the
     board. Until both are loaded the machine stays stopped and the screen is black.
  b. Mount a disk: drop an image on a drive, or use "Choose file". Drive 0 is the boot drive. Mount it, then press
     Reset. With no disk the CP-300 shows "Cass?" (cassette BASIC); with a TRSDOS disk it boots the DOS.
  c. Click the screen and type. The keys go to the CP-300:
         Esc = BREAK      Backspace or Left = left arrow      Home = CLEAR      Enter = ENTER
     The browser maps characters, not physical keys: a quote character presses the CP-300's shifted 2. An on-screen
     keyboard under the screen works by touch.
  d. Sound: click the "Sound" button once (browsers refuse audio before a click).
  e. Buttons: Reset, Turbo (faster CPU), Write-protect disks (all drives), Colour (green, amber, white).

Disks you change in the CP-300 are written back to the image on the board every two seconds. "Download" on a drive
gives you the image as DMK. "Eject" removes it. The picture is the machine's 512 x 192 monochrome output, shown on a
4:3 screen like the real tube.


4. Another gateware, and back
-----------------------------

The CP-300 gateware replaces the design that is in the board's flash. Flashing any other design - for example the
stock one,

    sudo /usr/share/beagleboard/gateware/change-gateware.sh default

- replaces it. The software and the Cockpit entry stay on the board and wait: the service starts only when the CP-300
gateware is loaded (Cockpit shows "Gateware: ... not loaded" meanwhile).

To use the CP-300 again, either run the installer once more or only flash the gateware:

    sudo cp300-load-gateware

The installer replaces the installed software and the sidebar entry every time, and flashes the gateware only if it is
not the one already loaded.

To upgrade to a newer package: unpack it and run its install.sh.


5. If something does not work
-----------------------------

  Black screen, or the machine stays stopped    The ROMs are missing: load both in the ROMs panel.
  Cockpit: "Gateware: not loaded"               Another design is loaded: sudo cp300-load-gateware
  Cockpit: "Daemon: not running"                systemctl status cp300d ; journalctl -u cp300d -e
                                                (the service starts only when /sys/class/uio/uio0/name says cp300)
  Page does not load at http://<board>/cp300/  sudo nginx -t ; systemctl status nginx ; try http://<board>:8300/ only
                                                if you start the daemon by hand
  No sound                                      click "Sound" first; check the browser tab is not muted
  Choppy picture                                the page shows its frame rate (about 40 fps; the hardware runs at 60)
  What is the hardware doing?                   curl http://localhost:8300/api/debug   (on the board: registers, bus timing)
  Check the installation                        ./install.sh --check
  nginx complains after an install              the installer keeps a copy of the original site file in
                                                /etc/nginx/cp300-default-site.backup ; --uninstall puts the site back in order
  The board does not come back after flashing   wait 5 minutes (do not power off); if it stays dead see the WARNING
                                                in section 1.


5b. Machines, tape and disks (software 0.13.0)
----------------------------------------------

  Machines (the selector on the page): CP-300, CP-400 (CoCo 2), MSX1, ZX Spectrum 48K, MC-1000, Alice (MC-10). Each needs
  its ROMs (uploaded on the page, kept on the board; none is in this package):
      CP-300   system 16 KB + character generator 2 KB       CP-400   Color BASIC + Extended BASIC 8 KB each (+ cartridge)
      MSX1     BIOS 32 KB (+ slot 0 page 2 ROM, cartridge, disk interface ROM)      ZX Spectrum  48K ROM 16 KB
      MC-1000  ROM 16 KB                                      Alice    the 8 KB BASIC of the original Alice / MC-10 (MC6847)
  The Alice's 6803 is emulated by a program compiled at the installation (alice_emu); if the compiler is missing the
  other machines are not affected.

  Cassette (all machines): the "Cassette" panel takes .tap (ZX Spectrum), .cas (the format of the machine selected: MSX,
  CoCo / MC-10, CP-300), .c10 / .k7 and .wav (converted by the page). Play runs the tape while the computer's motor is on
  (MSX, CP-400); the ZX Spectrum, MC-1000, Alice and CP-300 have no motor line: press Play when the computer asks for the
  tape (or tick the box to ignore the motor on any machine). Record collects what the machine writes: "Save recording"
  gives a WAV.

  MSX disks: the MSX1 has a disk interface in slot 2 (page 1) built around the CP-300's WD1793: the register layout is the
  one of the Gradiente Expert DD Plus ("National" type: WD2793 registers at $7FB8-$7FBB, control at $7FBC; read: b7 INTRQ,
  b6 DRQ; write: b1:0 drive, b2 side, b3 motor). Upload its 16 KB disk ROM on the page (the Expert DD Plus ROM works), then
  raw .dsk images (720 KB, 360 KB, 640 KB, 320 KB) in drives A and B. FORMAT does not work (no WRITE TRACK in the
  controller): use formatted images. Other disk interface layouts (Philips, Sony, Microsol ...) are not implemented.

6. What is in the package
-------------------------

  install.sh               the installer
  cp300-load-gateware      reflashes the CP-300 gateware (also installed as /usr/local/sbin/cp300-load-gateware)
  DISCLAIMER.txt           the full disclaimer (risk of bricking the board, no warranty, no liability)
  gateware/                the CP-300 gateware for the board: LinuxProgramming/mpfs_bitstream.spi, mpfs_dtbo.spi
  syn/beaglev-fire/host/   the daemon (cp300d.py), the register access helper (regs32.c) and the web page
  tools/dsk2dmk.py         converts .dsk .jv1 .jv3 .hfe images to DMK
  deploy/                  the service, the web server snippet, the Cockpit entry
  VERSION, GATEWARE_ID     package version and the gateware identifier the board reports once it is loaded
  SOURCE.txt               what was built, from which source, and the checksums of the gateware files
  LICENSE                  GNU GPL v3


Licence: GNU General Public License v3 (file LICENSE). The source of everything in this package, including the
gateware, is the CP-300_FPGA repository named in SOURCE.txt. Third-party parts keep their licences: the HT1080Z core
(BSD-style), T80, the WD1793 core (GPL-2.0-or-later), the BeagleV-Fire gateware framework (MIT) and the Microchip
Hart Software Services bootloader. ROMs and disk images are not part of this package.
