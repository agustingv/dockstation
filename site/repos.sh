#!/bin/sh
# Builds the signed APT and DNF repositories that installed copies update
# from, holding only the latest packages. Signs with gpg's default key.
#
# Usage: site/repos.sh <deb> <rpm> <out dir>
set -eu
deb=$1 rpm=$2 out=$3

apt="$out/apt"
dist="$apt/dists/stable"
mkdir -p "$apt/pool/main" "$dist/main/binary-amd64"
cp "$deb" "$apt/pool/main/"
(cd "$apt" && dpkg-scanpackages --arch amd64 pool /dev/null > dists/stable/main/binary-amd64/Packages)
gzip -9k "$dist/main/binary-amd64/Packages"
# Written outside the folder it lists, so it doesn't list itself.
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=DockStation \
  -o APT::FTPArchive::Release::Label=DockStation \
  -o APT::FTPArchive::Release::Suite=stable \
  -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures=amd64 \
  -o APT::FTPArchive::Release::Components=main \
  release "$dist" > "$out/Release"
mv "$out/Release" "$dist/Release"
gpg --batch --yes --clearsign -o "$dist/InRelease" "$dist/Release"
gpg --batch --yes --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"

mkdir -p "$out/rpm"
cp "$rpm" "$out/rpm/"
createrepo_c "$out/rpm"
gpg --batch --yes --armor --detach-sign "$out/rpm/repodata/repomd.xml"

cp "$(dirname "$0")/../packaging/dockstation.gpg" "$out/dockstation.gpg"
