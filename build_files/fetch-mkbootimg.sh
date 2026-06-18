#!/usr/bin/env bash
# Fetch AOSP mkbootimg at a pinned commit into <destdir>, sha256-verified.
set -euo pipefail

COMMIT=d2bb0af5ba6d3198a3e99529c97eda1be0b5a093
SHA_MKBOOTIMG=37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c
SHA_GKICERT=1bb1feec68a13da18d581aa2c631798f86f6bc10b55d587b2dd31446a0f8a203

dest="${1:?usage: fetch-mkbootimg.sh <destdir>}"
base="https://android.googlesource.com/platform/system/tools/mkbootimg/+/${COMMIT}"

mkdir -p "${dest}/gki"
curl --retry 3 --retry-delay 2 -fsSL "${base}/mkbootimg.py?format=TEXT" | base64 -d > "${dest}/mkbootimg.py"
curl --retry 3 --retry-delay 2 -fsSL "${base}/gki/generate_gki_certificate.py?format=TEXT" | base64 -d > "${dest}/gki/generate_gki_certificate.py"
echo "${SHA_MKBOOTIMG}  ${dest}/mkbootimg.py" | sha256sum -c -
echo "${SHA_GKICERT}  ${dest}/gki/generate_gki_certificate.py" | sha256sum -c -
