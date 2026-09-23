#!/bin/bash
# Build the Linux release asset for one tag on the Linux release host, the way
# linux-build.yml does on ubuntu-latest, in a throwaway ubuntu:24.04
# container. build.bat release pipes this over SSH from the Windows host:
#
#   ssh root@serrebiradio.com bash -s -- vX.Y.Z < tools/build_linux_remote.sh
#
# The only line on stdout is the directory holding the tarball and its sums.
set -euo pipefail

tag="$1"
work="$(mktemp -d /tmp/installthecli-linux-XXXXXX)"
git clone --quiet --depth 1 --branch "$tag" https://github.com/serrebidev/InstallTheCli-s.git "$work/src" >&2

# wxPython's PyPI wheels lag Ubuntu; use apt's in a venv that sees it.
docker run --rm -e TAG="$tag" -v "$work/src:/src" -w /src ubuntu:24.04 bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends python3 python3-venv python3-pip python3-wxgtk4.0 \
    binutils libgtk-3-0 libsdl2-2.0-0 libnotify4 libsm6 libxtst6 libgl1 libegl1 libglib2.0-0 >/dev/null
  python3 -m venv --system-site-packages /venv
  /venv/bin/pip install -q pyinstaller
  bash -n install_all_linux.sh
  /venv/bin/python -m PyInstaller --clean --noconfirm --log-level ERROR InstallTheCli.spec
  cd dist
  chmod +x InstallTheCli
  tar -czf "InstallTheCli-$TAG-linux.tar.gz" InstallTheCli
  sha256sum "InstallTheCli-$TAG-linux.tar.gz" > "InstallTheCli-$TAG-linux-SHA256SUMS.txt"
' >&2

mkdir "$work/out"
mv "$work/src/dist/InstallTheCli-$tag-linux.tar.gz" "$work/src/dist/InstallTheCli-$tag-linux-SHA256SUMS.txt" "$work/out/"
echo "$work/out"
