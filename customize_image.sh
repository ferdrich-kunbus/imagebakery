#!/bin/bash
# customize raspbian image for revolution pi

usage () {
	echo 'Usage: customize_image.sh [-m, --minimize | -h, --help] <image>
  -m, --minimize	Install only software that is necessary for basic operation (eg. Pictory and other RevPi tools)
  -h, --help		Print the usage page'
}

if [ "$#" != 1 ] ; then
	usage;
	exit 1
fi

if [ ! -x "$(which curl)" ]; then
	echo 1>&1 "Error: Command curl not found."
	exit 1
fi

if [ ! -x "$(which fsck.vfat)" ]; then
	echo 1>&1 "Error: Command fsck.vfat not found."
	exit 1
fi

if [ ! -x "$(which lsof)" ]; then
	echo 1>&1 "Error: Command lsof not found."
	exit 1
fi

PARTED="$(which parted)"
if [ "x$PARTED" = "x" ] ; then
	echo 1>&1 "Error: Command parted not found."
	exit 1
fi

if [ ! -x "$PARTED" ] ; then
	echo 1>&1 "Error: Command $PARTED is not executable."
	exit 1
fi

set -ex

# pivot to new PID namespace
if [ $$ != 2 ] && [ -x /usr/bin/newpid ] ; then
	exec /usr/bin/newpid "$0" "$@"
fi

# set MINIMG as 0: build the normal image by default
MINIMG=0

# get the options
if ! MYOPTS=$(getopt -o mh --long minimize,help -- "$@"); then
	usage;
	exit 1;
fi
eval set -- "$MYOPTS"

# extract options and their arguments into variables.
while true ; do
	case "$1" in
		-m|--minimize) MINIMG=1 ; shift ;;
		-h|--help) usage ; exit 0;;
		*) shift; break ;;
	esac
done

if [ "$MINIMG" != "1" ]; then
	echo "All additional applications will be built into the given image."
else
	echo "Only a reduced application set will be built into the given image."
fi

IMAGEDIR=`mktemp -d -p /tmp img.XXXXXXXX`
BAKERYDIR=$(dirname "$0")
LOOPDEVICE=$(losetup -f)
CONFIGTXT="$IMAGEDIR/boot/config.txt"

cleanup_umount() {
	if [ -e "$IMAGEDIR" ] ; then
		lsof -t "$IMAGEDIR" | xargs --no-run-if-empty kill
	fi
	if [ -e "$IMAGEDIR/usr/bin/qemu-arm-static" ] ; then
		rm -f "$IMAGEDIR/usr/bin/qemu-arm-static"
	fi
	if mountpoint -q "$IMAGEDIR/tmp/debs-to-install" ; then
		umount "$IMAGEDIR/tmp/debs-to-install"
	fi
	if [ -e "$IMAGEDIR/tmp/debs-to-install" ] ; then
		rmdir "$IMAGEDIR/tmp/debs-to-install"
	fi
	if mountpoint -q "$IMAGEDIR/boot" ; then
		umount "$IMAGEDIR/boot"
	fi
	if mountpoint -q "$IMAGEDIR" ; then
		umount "$IMAGEDIR"
	fi
	if [ -d "$IMAGEDIR" ] ; then
		rmdir "$IMAGEDIR"
	fi
}

cleanup_losetup() {
	if [ -e "$LOOPDEVICE"p1 ] ; then
		delpart "$LOOPDEVICE" 1
	fi
	if [ -e "$LOOPDEVICE"p2 ] ; then
		delpart "$LOOPDEVICE" 2
	fi
	if losetup "$LOOPDEVICE" 2>/dev/null ; then
		losetup -d "$LOOPDEVICE"
	fi
}

cleanup() {
	cleanup_umount
	cleanup_losetup
}

trap cleanup ERR SIGINT
imgsize=$($PARTED "$1" unit b print | grep -e "\.img" | awk -F ":" '{gsub(/^[ \t]+|[B \t]+$/,"",$2); print $2}')
[ "x$imgsize" = "x" ] && echo 1>&1 "Error: Image size not found" && exit 1
secsize=$($PARTED "$1" unit b print | grep -e "Sector size" | awk -F "/" '{gsub(/^[ \t]+|[B \t]+$/,"",$3); print $3}')
[ "x$secsize" = "x" ] && echo 1>&1 "Error: Sector size not found" && exit 1

# The smallest size of CM3-eMMC is 4 GB  , the available disksize for a system is 3909091328 bytes
# An image like raspios-lite just have 2 GB , so we need to resize rootfs first before
# we start processing the image. Otherwise build will fail with "no space left on device"
if [ $imgsize -lt 3900000000 ] ; then
	disksize=3909091328
	bcount=$(echo "($disksize-$imgsize)/$secsize" | bc )
	dd if=/dev/zero count=$bcount bs=$secsize >> "$1"
	$PARTED "$1" resizepart 2 "$((disksize-1))"B
	losetup "$LOOPDEVICE" "$1"
	partprobe "$LOOPDEVICE"
	resize2fs "$LOOPDEVICE"p2
	e2fsck -p -f "$LOOPDEVICE"p2
	sync
	losetup -D
fi

# mount ext4 + FAT filesystems
losetup "$LOOPDEVICE" "$1"
partprobe "$LOOPDEVICE"
mount "$LOOPDEVICE"p2 "$IMAGEDIR"
mount "$LOOPDEVICE"p1 "$IMAGEDIR/boot"

# see https://wiki.debian.org/QemuUserEmulation
if [ -e /usr/bin/qemu-arm-static ] ; then
	cp /usr/bin/qemu-arm-static "$IMAGEDIR/usr/bin"
fi

# copy templates
cp "$BAKERYDIR/templates/config.txt" "$IMAGEDIR/boot"
cp "$BAKERYDIR/templates/cmdline.txt" "$IMAGEDIR/boot"
cp "$BAKERYDIR/templates/revpi-aliases.sh" "$IMAGEDIR/etc/profile.d"
cp "$BAKERYDIR/templates/rsyslog.conf" "$IMAGEDIR/etc"

# limit disk space occupied by logs
ln -s ../cron.daily/logrotate "$IMAGEDIR/etc/cron.hourly"
sed -r -i -e 's/delaycompress/#delaycompress/' \
	  -e 's/sharedscripts/#sharedscripts/' \
	  "$IMAGEDIR/etc/logrotate.d/rsyslog"
sed -r -i -e 's/#compress/compress/' -e '2i \
\
# limit size of each log file\
maxsize 10M\
\
# compress harder\
compresscmd /usr/bin/nice\
compressoptions /usr/bin/xz\
compressext .xz\
uncompresscmd /usr/bin/unxz\
' "$IMAGEDIR"/etc/logrotate.conf

# bootstrap apt source, will be overwritten by revpi-repo package
cp "$BAKERYDIR/templates/revpi.gpg" "$IMAGEDIR/etc/apt/trusted.gpg.d"
cp "$BAKERYDIR/templates/revpi.list" "$IMAGEDIR/etc/apt/sources.list.d"

# Move ld.so.preload until installation is finished. Otherwise we get errors
# from ld.so:
#   ERROR: ld.so: object '/usr/lib/arm-linux-gnueabihf/libarmmem-${PLATFORM}.so'
#   from /etc/ld.so.preload cannot be preloaded (cannot open shared object file): ignored.
mv "$IMAGEDIR/etc/ld.so.preload" "$IMAGEDIR/etc/ld.so.preload.bak"

# copy piTest source code
PICONTROLDIR=`mktemp -d -p /tmp piControl.XXXXXXXX`
git clone https://github.com/RevolutionPi/piControl $PICONTROLDIR
cp -pr $PICONTROLDIR/piTest "$IMAGEDIR/home/pi/demo"
cp -p $PICONTROLDIR/piControl.h "$IMAGEDIR/home/pi/demo"
sed -i -r -e 's%\.\./%%' "$IMAGEDIR/home/pi/demo/Makefile"
chown -R 1000:1000 "$IMAGEDIR/home/pi/demo"
chmod -R a+rX "$IMAGEDIR/home/pi/demo"
rm -r $PICONTROLDIR

# remove bookshelf if present
if [[ -d $IMAGEDIR/home/pi/Bookshelf ]]; then
    rm -r $IMAGEDIR/home/pi/Bookshelf
fi

# customize settings
echo Europe/Berlin > "$IMAGEDIR/etc/timezone"
rm "$IMAGEDIR/etc/localtime"
echo RevPi > "$IMAGEDIR/etc/hostname"
sed -i -e 's/raspberrypi/RevPi/g' "$IMAGEDIR/etc/hosts"
if ! grep -qE '^i2c-dev$' "$IMAGEDIR/etc/modules" ; then
	echo i2c-dev >> "$IMAGEDIR/etc/modules"
fi
echo piControl >> "$IMAGEDIR/etc/modules"
sed -i -r -e 's/^(XKBMODEL).*/\1="pc104"/' \
	-e 's/^(XKBLAYOUT).*/\1="us"/' \
	-e 's/^(XKBVARIANT).*/\1=""/' \
	  "$IMAGEDIR/etc/default/keyboard"
sed -i -r -e 's/^(LANG).*/\1="en_US.UTF-8"/' "$IMAGEDIR/etc/default/locale"
sed -i -r -e 's/^(# en_US.UTF-8 UTF-8)/en_US.UTF-8 UTF-8/' "$IMAGEDIR/etc/locale.gen"
install -d -m 755 -o root -g root "$IMAGEDIR/etc/revpi"
echo `basename "$1"` > "$IMAGEDIR/etc/revpi/image-release"
install -d -m 700 -o 1000 -g 1000 "$IMAGEDIR/home/pi/.ssh"

# activate settings
chroot "$IMAGEDIR" dpkg-reconfigure -fnoninteractive keyboard-configuration
chroot "$IMAGEDIR" dpkg-reconfigure -fnoninteractive tzdata
chroot "$IMAGEDIR" dpkg-reconfigure -fnoninteractive locales

# automatically bring up eth0 and eth1 again after a USB bus reset
sed -i -e '6i# allow-hotplug eth0\n# allow-hotplug eth1\n' "$IMAGEDIR/etc/network/interfaces"

# provide WPA template and prioritize wlan0 routes by default
sed -i -e '/country=GB/d' "$IMAGEDIR/etc/wpa_supplicant/wpa_supplicant.conf"
cat >> "$IMAGEDIR/etc/wpa_supplicant/wpa_supplicant.conf" <<-EOF
	
	# WiFi of Revolutionary Pastries, Inc.
	network={
	        ssid=""
	        psk=""
	        key_mgmt=WPA-PSK
	}
	EOF
cat >> "$IMAGEDIR/etc/dhcpcd.conf" <<-EOF
	
	# Prioritize wlan0 routes over eth0 routes.
	interface wlan0
	        metric 100
	EOF

# harden network configuration
chroot "$IMAGEDIR" /usr/bin/patch /etc/sysctl.conf	\
	< "$BAKERYDIR/templates/sysctl.conf.patch"

# display IP address at login prompt
sed -i -e '1s/$/ \\4 \\6/' "$IMAGEDIR/etc/issue"

# free up disk space
dpkg --root "$IMAGEDIR" --purge `egrep -v '^#' "$BAKERYDIR/debs-to-remove"`
chroot "$IMAGEDIR" apt-get -y autoremove --purge
rm -rf "$IMAGEDIR/home/pi/MagPi"

# avoid installing unnecessary packages on this space-constrained machine
echo 'APT::Install-Recommends "false";' >> "$IMAGEDIR/etc/apt/apt.conf"

# download and install missing packages
sed -r -i -e '1ideb http://mirrordirector.raspbian.org/raspbian buster main' "$IMAGEDIR/etc/apt/sources.list"
chroot "$IMAGEDIR" apt-get update --allow-releaseinfo-change -y
chroot "$IMAGEDIR" apt-get -y install apt apt-transport-https libapt-inst2.0 libapt-pkg5.0
sed -r -i -e '1d' "$IMAGEDIR/etc/apt/apt.conf" "$IMAGEDIR/etc/apt/sources.list"

chroot "$IMAGEDIR" apt-get -y install `egrep -v '^#' "$BAKERYDIR/min-debs-to-download"`
if [ "$MINIMG" != "1" ]; then
	chroot "$IMAGEDIR" apt-get -y install `egrep -v '^#' "$BAKERYDIR/debs-to-download"`
fi
dpkg --root "$IMAGEDIR" --force-depends --purge rpd-wallpaper
chroot "$IMAGEDIR" apt-get -y install revpi-wallpaper
chroot "$IMAGEDIR" apt-get update
if [ "$MINIMG" != "1" ]; then
	chroot "$IMAGEDIR" apt-get -y install teamviewer-revpi
fi
chroot "$IMAGEDIR" apt-mark hold raspi-copies-and-fills
chroot "$IMAGEDIR" apt-get -y upgrade
chroot "$IMAGEDIR" apt-mark unhold raspi-copies-and-fills
chroot "$IMAGEDIR" apt-get clean

if [ -e "$IMAGEDIR/etc/init.d/apache2" ] ; then
	# annoyingly, the postinstall script starts apache2 on fresh installs
	mount -t proc procfs "$IMAGEDIR/proc"
	sed -r -i -e 's/pidof /pidof -x /' "$IMAGEDIR/etc/init.d/apache2"
	chroot "$IMAGEDIR" /etc/init.d/apache2 stop
	umount "$IMAGEDIR/proc"

	# configure apache2
	chroot "$IMAGEDIR" a2enmod ssl
	sed -r -i -e 's/^(\tOptions .*Indexes.*)/#\1/'		\
		"$IMAGEDIR/etc/apache2/apache2.conf"
fi

if [ "$MINIMG" != "1" ]; then
	# install nodejs and nodered with an install script and revpi-nodes from npm repository
	NODEREDSCRIPT="/tmp/update-nodejs-and-nodered.sh"
	/usr/bin/curl -sL \
		https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered\
		--output "$IMAGEDIR/$NODEREDSCRIPT"
	chmod 755 "$IMAGEDIR/$NODEREDSCRIPT"
	chroot "$IMAGEDIR" /usr/bin/sudo -u pi $NODEREDSCRIPT --confirm-install --confirm-pi
	rm "$IMAGEDIR/$NODEREDSCRIPT"
	chroot "$IMAGEDIR" /usr/bin/sudo -u pi /usr/bin/npm install --prefix /home/pi/.node-red node-red-contrib-revpi-nodes
fi
# enable ssh daemon by default, disable swap, disable bluetooth on mini-uart
chroot "$IMAGEDIR" systemctl enable ssh
chroot "$IMAGEDIR" systemctl disable dphys-swapfile
chroot "$IMAGEDIR" systemctl disable hciuart

# disable 3rd party software
if [ "$MINIMG" != "1" ]; then
	chroot "$IMAGEDIR" systemctl disable logiclab
	chroot "$IMAGEDIR" systemctl disable nodered
fi
chroot "$IMAGEDIR" systemctl disable noderedrevpinodes-server
chroot "$IMAGEDIR" systemctl disable revpipyload

# boot to console by default, disable autologin
chroot "$IMAGEDIR" systemctl set-default multi-user.target
ln -fs /lib/systemd/system/getty@.service		\
	"$IMAGEDIR/etc/systemd/system/getty.target.wants/getty@tty1.service"
if [ -e "$IMAGEDIR/etc/lightdm/lightdm.conf" ] ; then
	sed -r -i -e "s/^autologin-user=/#autologin-user=/"	\
		"$IMAGEDIR/etc/lightdm/lightdm.conf"
fi

# autologin.conf enables autologin in raspios and raspios-full 
# but not in raspios-lite
if [ -e "$IMAGEDIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" ] ; then
	rm -f "$IMAGEDIR/etc/systemd/system/getty@tty1.service.d/autologin.conf"
fi

# peg cpu at 1200 MHz to maximize spi0 throughput and avoid jitter
chroot "$IMAGEDIR" /usr/bin/revpi-config enable perf-governor

# remove package lists, they will be outdated within days
rm "$IMAGEDIR/var/lib/apt/lists/"*Packages

# install local packages
if [ "$(/bin/ls "$BAKERYDIR/debs-to-install/"*.deb 2>/dev/null)" ] ; then
	mkdir "$IMAGEDIR/tmp/debs-to-install"
	mount --bind "$BAKERYDIR/debs-to-install" "$IMAGEDIR/tmp/debs-to-install"
	chroot "$IMAGEDIR" sh -c "dpkg -i /tmp/debs-to-install/*.deb"
fi

# remove logs and ssh host keys
find "$IMAGEDIR/var/log" -type f -delete
find "$IMAGEDIR/etc/ssh" -name "ssh_host_*_key*" -delete

# restore ld.so.preload
mv "$IMAGEDIR/etc/ld.so.preload.bak" "$IMAGEDIR/etc/ld.so.preload"

cleanup_umount

fsck.vfat -a "$LOOPDEVICE"p1
sleep 2
fsck.ext4 -f -p "$LOOPDEVICE"p2
sleep 2

# shrink image to speed up flashing
resize2fs -M "$LOOPDEVICE"p2
PARTSIZE=$(dumpe2fs -h "$LOOPDEVICE"p2 | egrep "^Block count:" | cut -d" " -f3-)
PARTSIZE=$((($PARTSIZE) * 8))   # ext4 uses 4k blocks, partitions use 512 bytes
PARTSTART=$(cat /sys/block/$(basename "$LOOPDEVICE")/$(basename "$LOOPDEVICE"p2)/start)
echo Yes | $PARTED ---pretend-input-tty "$LOOPDEVICE" resizepart 2 "$(($PARTSTART+$PARTSIZE-1))"s
cleanup_losetup
truncate -s $((512 * ($PARTSTART + $PARTSIZE))) "$1"
