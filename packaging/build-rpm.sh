#!/bin/sh
# Builds the .rpm from this checkout into <out dir>. Needs the spec's build dependencies.
#
# Usage: packaging/build-rpm.sh <version> <out dir>
set -eu
version=$1 out=$2

rpmbuild -bb --build-in-place \
  --define "app_version $version" \
  --define "_rpmdir $PWD/.rpmbuild" \
  packaging/dockstation.spec
mkdir -p "$out"
mv .rpmbuild/*/*.rpm "$out/"
