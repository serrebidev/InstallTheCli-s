#!/bin/bash
# Build the Linux release asset for one tag on the Linux release host (local WSL Ubuntu, ssh alias wsl-build), the way
# linux-build.yml does on ubuntu-latest, in a throwaway ubuntu:24.04
# container. build.bat release pipes this over SSH from the Windows host:
#
#   ssh wsl-build bash -s -- vX.Y.Z < tools/build_linux_remote.sh
#
# The only line on stdout is the directory holding the tarball and its sums.
set -euo pipefail

# Host caches mounted into the container: apt .debs per repo (apt locks its
# archive dir), pip wheels shared (pip keeps wheels it builds from source).
# --cpu-shares 26214: build outranks everything except live radio/TV on the host
# (see /usr/local/bin/live-priority.sh there).

tag="$1"
work="$(mktemp -d /tmp/installthecli-linux-XXXXXX)"
git clone --quiet --depth 1 --branch "$tag" https://git.serrebiradio.com/serrebi/InstallTheCli-s.git "$work/src" >&2

# wxPython's PyPI wheels lag Ubuntu; use apt's in a venv that sees it.
docker run --rm --cpu-shares 26214 -v /var/cache/release-build/installthecli-apt:/var/cache/apt/archives -v /var/cache/release-build/pip:/root/.cache/pip -e TAG="$tag" -v "$work/src:/src" -w /src ubuntu:24.04 bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  rm -f /etc/apt/apt.conf.d/docker-clean  # keep .debs in the mounted host cache
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends python3 python3-venv python3-pip python3-wxgtk4.0 libpython3.12 git \
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
