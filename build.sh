#!/bin/sh

# Exit on errors
set -e

version="12.2"
pkgset="branches/2020Q1" # TODO: Use it
desktop=$1
tag=$2
cwd=$(realpath | sed 's|/scripts||g')
workdir="/usr/local"
livecd="${workdir}/furybsd"
if [ -z "${arch}" ] ; then
  arch=amd64
fi
cache="${livecd}/${arch}/cache"
base="${cache}/${version}/base"
packages="${cache}/packages"
iso="${livecd}/iso"
  if [ -n "$CIRRUS_CI" ] ; then
    # On Cirrus CI ${livecd} is in tmpfs for speed reasons
    # and tends to run out of space. Writing the final ISO
    # to non-tmpfs should be an acceptable compromise
    iso="${CIRRUS_WORKING_DIR}/artifacts"
  fi
uzip="${livecd}/uzip"
cdroot="${livecd}/cdroot"
ramdisk_root="${cdroot}/data/ramdisk"
vol="furybsd"
label="FURYBSD"
export DISTRIBUTIONS="kernel.txz base.txz"

# Only run as superuser
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Make sure git is installed
# We only need this in case we decide to pull in ingredients from
# other git repositories; this is currently not the case
# if [ ! -f "/usr/local/bin/git" ] ; then
#   echo "Git is required"
#   echo "Please install it with pkg install git or pkg install git-lite first"
#   exit 1
# fi

if [ -z "${desktop}" ] ; then
  export desktop=xfce
fi
edition=$(echo $desktop | tr '[:lower:]' '[:upper:]')
export edition
if [ ! -f "${cwd}/settings/packages.${desktop}" ] ; then
  echo "${cwd}/settings/packages.${desktop} is missing, exiting"
  exit 1
fi

# Get the version tag
if [ -z "$2" ] ; then
  rm /usr/local/furybsd/tag >/dev/null 2>/dev/null || true
  export vol="FuryBSD-${version}-${edition}"
else
  rm /usr/local/furybsd/version >/dev/null 2>/dev/null || true
  echo "${2}" > /usr/local/furybsd/tag
  export vol="FuryBSD-${version}-${edition}-${tag}"
fi

label="FURYBSD"
isopath="${iso}/${vol}-${arch}.iso"

cleanup()
{
  if [ -n "$CIRRUS_CI" ] ; then
    # On CI systems there is no reason to clean up which takes time
    return 0
  else
    umount ${uzip}/var/cache/pkg >/dev/null 2>/dev/null || true
    umount ${uzip}/dev >/dev/null 2>/dev/null || true
    zpool destroy -f furybsd >/dev/null 2>/dev/null || true
    mdconfig -d -u 0 >/dev/null 2>/dev/null || true
    rm ${livecd}/pool.img >/dev/null 2>/dev/null || true
    rm -rf ${cdroot} >/dev/null 2>/dev/null || true
  fi
}

workspace()
{
  mkdir -p "${livecd}" "${base}" "${iso}" "${packages}" "${uzip}" "${ramdisk_root}/dev" "${ramdisk_root}/etc" >/dev/null 2>/dev/null
  truncate -s 3g "${livecd}/pool.img"
  mdconfig -f "${livecd}/pool.img" -u 0
  gpart create -s GPT md0
  gpart add -t freebsd-zfs md0
  zpool create furybsd /dev/md0p1
  zfs set mountpoint="${uzip}" furybsd
  zfs set compression=gzip-6 furybsd
}

base()
{
  # TODO: Signature checking
  if [ ! -f "${base}/base.txz" ] ; then 
    cd ${base}
    fetch https://download.freebsd.org/ftp/releases/${arch}/${version}-RELEASE/base.txz
  fi
  
  if [ ! -f "${base}/kernel.txz" ] ; then
    cd ${base}
    fetch https://download.freebsd.org/ftp/releases/${arch}/${version}-RELEASE/kernel.txz
  fi
  cd ${base}
  tar -zxvf base.txz -C ${uzip}
  tar -zxvf kernel.txz -C ${uzip}
  touch ${uzip}/etc/fstab
}

packages()
{
  cp /etc/resolv.conf ${uzip}/etc/resolv.conf
  mkdir ${uzip}/var/cache/pkg
  mount_nullfs ${packages} ${uzip}/var/cache/pkg
  mount -t devfs devfs ${uzip}/dev
  # FIXME: In the following line, the hardcoded "i386" needs to be replaced by "${arch}" - how?
  cat "${cwd}/settings/packages.common" | sed '/^#/d' | sed '/\!i386/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" install -y
  while read -r p; do
    /usr/local/sbin/pkg-static -c ${uzip} install -y /var/cache/pkg/"${p}"-0.txz
  done <"${cwd}"/settings/overlays.common
  # TODO: Show dependency tree so that we know why which pkgs get installed
  # cat "${cwd}/settings/packages.common" | sed '/^#/d' | sed '/\!'"${arch}"'/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" info -d
  # cat "${cwd}/settings/packages.${desktop}" | sed '/^#/d' | sed '/\!'"${arch}"'/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" info -d
  cat "${cwd}/settings/packages.${desktop}" | sed '/^#/d' | sed '/\!i386/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" install -y
  if [ -f "${cwd}/settings/overlays.${desktop}" ] ; then
    while read -r p; do
      /usr/local/sbin/pkg-static -c ${uzip} install -y /var/cache/pkg/"${p}"-0.txz
    done <"${cwd}/settings/overlays.${desktop}"
  fi
  /usr/local/sbin/pkg-static -c ${uzip} info > "${cdroot}/data/system.uzip.manifest"
  cp "${cdroot}/data/system.uzip.manifest" "${isopath}.manifest"
  rm ${uzip}/etc/resolv.conf
  umount ${uzip}/var/cache/pkg
  umount ${uzip}/dev
}

rc()
{
  if [ ! -f "${uzip}/etc/rc.conf" ] ; then
    touch ${uzip}/etc/rc.conf
  fi
  if [ ! -f "${uzip}/etc/rc.conf.local" ] ; then
    touch ${uzip}/etc/rc.conf.local
  fi
  cat "${cwd}/settings/rc.conf.common" | xargs chroot "${uzip}" sysrc -f /etc/rc.conf.local
  cat "${cwd}/settings/rc.conf.${desktop}" | xargs chroot "${uzip}" sysrc -f /etc/rc.conf.local
}


repos()
{
  # This is just an example of how a git repo needs to be structured
  # so that it can be consumed directly here
  # if [ ! -d "${cwd}/overlays/uzip/furybsd-common-settings" ] ; then
  #   git clone https://github.com/probonopd/furybsd-common-settings.git ${cwd}/overlays/uzip/furybsd-common-settings
  # else
  #   cd ${cwd}/overlays/uzip/furybsd-common-settings && git pull
  # fi
  true
}

user()
{
  mkdir -p ${uzip}/usr/home/liveuser/Desktop
  # chroot ${uzip} echo furybsd | chroot ${uzip} pw mod user root -h 0
  chroot ${uzip} pw useradd liveuser -u 1000 \
  -c "Live User" -d "/home/liveuser" \
  -g wheel -G operator -m -s /bin/csh -k /usr/share/skel -w none
  chroot ${uzip} pw groupadd liveuser -g 1000
  # chroot ${uzip} echo furybsd | chroot ${uzip} pw mod user liveuser -h 0
  chroot ${uzip} chown -R 1000:1000 /usr/home/liveuser
  chroot ${uzip} pw groupmod wheel -m liveuser
  chroot ${uzip} pw groupmod video -m liveuser
  chroot ${uzip} pw groupmod webcamd -m liveuser
}

dm()
{
  case $desktop in
    'kde')
      ;;
    'gnome')
      ;;
    'lumina')
      ;;
    'mate')
      chroot ${uzip} sed -i '' -e 's/memorylocked=128M/memorylocked=256M/' /etc/login.conf
      chroot ${uzip} cap_mkdb /etc/login.conf
      ;;
    'xfce')
      ;;
  esac
}

# Generate on-the-fly packages for the selected overlays
pkg()
{
  cd "${packages}"
  while read -r p; do
    sh -ex "${cwd}/scripts/build-pkg.sh" -m "${cwd}/overlays/uzip/${p}"/manifest -d "${cwd}/overlays/uzip/${p}/files"
  done <"${cwd}"/settings/overlays.common
  if [ -f "${cwd}/settings/overlays.${desktop}" ] ; then
    while read -r p; do
      sh -ex "${cwd}/scripts/build-pkg.sh" -m "${cwd}/overlays/uzip/${p}"/manifest -d "${cwd}/overlays/uzip/${p}/files"
    done <"${cwd}/settings/overlays.${desktop}"
  fi
  cd -
}

uzip() 
{
  install -o root -g wheel -m 755 -d "${cdroot}"
  cd ${cwd} && zpool export furybsd && while zpool status furybsd >/dev/null; do :; done 2>/dev/null
  mkuzip -S -d -o "${cdroot}/data/system.uzip" "${livecd}/pool.img"
}

ramdisk() 
{
  cp -R "${cwd}/overlays/ramdisk/" "${ramdisk_root}"
  cd ${cwd} && zpool import furybsd && zfs set mountpoint=/usr/local/furybsd/uzip furybsd 
  cd "${uzip}" && tar -cf - rescue | tar -xf - -C "${ramdisk_root}"
  touch "${ramdisk_root}/etc/fstab"
  cp ${uzip}/etc/login.conf ${ramdisk_root}/etc/login.conf
  makefs -b '10%' "${cdroot}/data/ramdisk.ufs" "${ramdisk_root}"
  gzip -f "${cdroot}/data/ramdisk.ufs"
  rm -rf "${ramdisk_root}"
}

boot() 
{
  cp -R "${cwd}/overlays/boot/" "${cdroot}"
  cd "${uzip}" && tar -cf - --exclude boot/kernel boot | tar -xf - -C "${cdroot}"
  for kfile in kernel geom_uzip.ko opensolaris.ko tmpfs.ko xz.ko zfs.ko; do
  tar -cf - boot/kernel/${kfile} | tar -xf - -C "${cdroot}"
  done
  cd ${cwd} && zpool export furybsd && mdconfig -d -u 0
}

image()
{
  sh "${cwd}/scripts/mkisoimages-${arch}.sh" -b "${label}" "${isopath}" "${cdroot}"
  md5 "${isopath}" > "${isopath}.md5"
  echo "$isopath created"
}
echo "1 CLEANUP"
cleanup
echo "2 WORKSPACE"
workspace
echo "3 REPOS"
repos
echo "4 PKG"
pkg
echo "5 BASE"
base
echo "6 PACKAGES"
packages
echo "7 RC"
rc
echo "8 USER"
user
echo "9 DM"
dm
echo "10 UZIP"
uzip
echo "11 RAMDISK"
ramdisk
echo "12 BOOT"
boot
echo "13 IMAGE"
image
