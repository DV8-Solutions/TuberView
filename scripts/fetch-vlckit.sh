#!/bin/bash
# Downloads VLC's playback engine (VLCKit) from VideoLAN and checks it is the
# exact file expected before using it.
set -euo pipefail

NAME="VLCKit-3.6.0-c73b779f-dd8bfdba"
URL="https://download.videolan.org/pub/cocoapods/prod/${NAME}.tar.xz"
SHA256="23f8f7bb0f8e0321393f51ad5da65ea37ecbc1e148ac2d97fd9f05073ec01075"
DEST="Vendor/VLCKit.xcframework"

cd "$(dirname "$0")/.."

if [ -d "$DEST" ]; then
    echo "VLCKit is already in place."
    exit 0
fi

mkdir -p Vendor
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ${NAME}…"
curl -fL --retry 3 --retry-delay 5 -o "$TMP/vlckit.tar.xz" "$URL"
echo "${SHA256}  $TMP/vlckit.tar.xz" | shasum -a 256 -c -

tar -xJf "$TMP/vlckit.tar.xz" -C "$TMP"
FOUND="$(find "$TMP" -maxdepth 4 -type d -name 'VLCKit.xcframework' | head -n 1)"
if [ -z "$FOUND" ]; then
    echo "VLCKit.xcframework was not in the download. It contained:"
    find "$TMP" -maxdepth 3
    exit 1
fi
mv "$FOUND" "$DEST"
echo "VLCKit is ready:"
ls "$DEST"
