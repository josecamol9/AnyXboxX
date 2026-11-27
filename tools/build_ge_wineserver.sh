#!/bin/bash
# Build a GE-Proton wineserver with the view-tree patch (CachyOS/wine-cachyos#50, Wine bug 60868) and make a copy
# of that GE-Proton with only files/bin/wineserver replaced.
#
#   tools/build_ge_wineserver.sh <GE tag, e.g. GE-Proton11-14> <installed GE-Proton dir> <work dir>
#
# Steps: fetch proton-ge-custom at the commit pinned for the tag, fetch its wine and wine-staging submodules at the
# commits that pins, run the wine section of GE's patches/protonprep-valve-staging.sh, generate the headers configure
# needs, apply the patch (checked against its pinned sha256), build only server/wineserver, check its protocol
# version against the installed Proton's ntdll.so, copy the Proton.
set -euo pipefail

# The patch: ajsem1337's commit on CachyOS/wine-cachyos (from a version by neonbyte1), LGPL-2.1-or-later as Wine.
PATCH_URL=https://github.com/CachyOS/wine-cachyos/commit/fd66dbca8eb0754839ca974e45b5ea446ca62d2f.patch
PATCH_SHA256=9ee40d566e17602b86d5a98cc26823244b5252718e636d037047154b9a0da74b
GE_URL=https://github.com/GloriousEggroll/proton-ge-custom

# The proton-ge-custom commit each supported tag names (tags can move; commits can't).
ge_commit() {
  case "$1" in
    GE-Proton11-14) echo 777d72b4ae50b3121ac46df2a7605bb2d6156840 ;;
    *) return 1 ;;
  esac
}

# Fails unless the installed Proton's ntdll.so speaks wineserver protocol $2.
check_protocol() {
  local inst=$1 version=$2 n
  n=$(objdump -d --no-show-raw-insn "$inst/files/lib/wine/x86_64-unix/ntdll.so" \
        | grep -cE "(cmp|mov) +\\\$0x$(printf %x "$version"),") || true
  [ "$n" -ge 1 ] || { echo "protocol $version not found in $inst ntdll.so: wrong source for this Proton" >&2; return 1; }
  echo "protocol $version matches $inst ($n hits)"
}

# Copies the Proton folder $1 to $3 with only files/bin/wineserver replaced by $2.
copy_proton() {
  local inst=$1 server=$2 out=$3
  [ -e "$out" ] && { echo "$out exists: remove it first" >&2; return 1; }
  cp -a "$inst" "$out"; cp "$server" "$out/files/bin/wineserver"
}

main() {
  local TAG INST WORK GE_SHA m url sha P s e V OUT
  TAG=${1:?GE tag}; INST=$(realpath "${2:?installed GE-Proton dir}"); WORK=${3:?work dir}
  GE_SHA=$(ge_commit "$TAG") || { echo "no pinned commit for $TAG: add it to ge_commit" >&2; exit 1; }
  mkdir -p "$WORK"; WORK=$(realpath "$WORK"); cd "$WORK"
  [ -e src ] && { echo "$WORK/src exists: use an empty work dir" >&2; exit 1; }

  git init -q src; git -C src fetch -q --depth 1 "$GE_URL" "$GE_SHA"; git -C src checkout -q FETCH_HEAD
  cd src
  for m in wine wine-staging; do
    url=$(git config -f .gitmodules "submodule.$m.url"); sha=$(git ls-tree HEAD "$m" | awk '{print $3}')
    rm -rf "$m"; git init -q "$m"; git -C "$m" fetch -q --depth 1 "$url" "$sha"; git -C "$m" checkout -q FETCH_HEAD
    echo "$m $url $sha"
  done
  P=patches/protonprep-valve-staging.sh
  s=$(grep -n '^### (2) WINE PATCHING ###' $P | cut -d: -f1); e=$(grep -n '^### END WINE PATCHING ###' $P | cut -d: -f1)
  { sed -n '1,/^### (1) PREP SECTION ###/p' $P | head -n -1; sed -n "${s},${e}p" $P; } > ../ge-prep-wine.sh
  bash ../ge-prep-wine.sh > ../prep.log 2>&1
  cd wine
  XDG_CACHE_HOME="$WORK/cache" dlls/winevulkan/make_vulkan -x vk.xml -X video.xml > ../../vk.log 2>&1
  tools/make_specfiles > ../../spec.log 2>&1
  curl -fsSL "$PATCH_URL" -o ../../viewtree.patch
  echo "$PATCH_SHA256  ../../viewtree.patch" | sha256sum -c --quiet - \
    || { echo "the patch's sha256 is not the pinned one: refusing it" >&2; exit 1; }
  git apply ../../viewtree.patch
  V=$(sed -n 's/^#define SERVER_PROTOCOL_VERSION //p' include/wine/server_protocol.h)
  check_protocol "$INST" "$V"

  mkdir -p "$WORK/build"; cd "$WORK/build"
  ../src/wine/configure --enable-win64 --disable-tests --without-x --without-freetype --without-gnutls --without-vulkan \
    --without-opengl --without-alsa --without-pulse --without-gstreamer --without-sdl --without-udev --without-usb \
    --without-v4l2 --without-cups --without-dbus --without-krb5 --without-netapi --without-pcap --without-sane \
    --without-unwind --without-wayland --without-xinerama --without-xrandr --without-xinput2 --without-xcomposite \
    --without-xcursor --without-xfixes --without-xshape --without-xshm --without-osmesa --without-fontconfig \
    --without-gphoto --without-ffmpeg --without-capi --without-pcsclite --without-coreaudio --without-oss \
    --without-mingw > configure.log 2>&1
  make -j"$(nproc)" server/wineserver > make.log 2>&1
  strip -o wineserver server/wineserver
  OUT="$WORK/$(basename "$INST")-viewtree"
  copy_proton "$INST" wineserver "$OUT"
  echo "done: $OUT (only files/bin/wineserver replaced); use PROTON=$OUT/proton"
}

# Sourced (by tests/test_build_ge_wineserver.py), it only defines the functions above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
