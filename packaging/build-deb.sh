#!/bin/sh
# Builds the .deb from this checkout into <out dir>. Needs debian/control's build
# dependencies. The changelog is written here so that the version lives in meson.build.
#
# Usage: packaging/build-deb.sh <version> <out dir>
set -eu
version=$1 out=$2

cat > debian/changelog <<CHANGELOG
dockstation ($version-1) stable; urgency=medium

  * New release, see https://github.com/agustingv/dockstation/releases

 -- Agustin Garcia <contacto@agustin-garcia.es>  $(date -R)
CHANGELOG
DEB_BUILD_OPTIONS=noautodbgsym dpkg-buildpackage --build=binary --no-sign
mkdir -p "$out"
mv ../dockstation_"$version"-1_*.deb "$out/"
