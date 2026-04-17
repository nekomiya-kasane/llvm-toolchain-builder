#!/usr/bin/env bash
# install-git.sh — Ensure git >= 2.18 is available in the container.
# On Ubuntu 16.04, system git is 2.7.4 which is too old for actions/checkout@v3.
# This script builds git 2.47.2 from source if the system git is insufficient.
set -euo pipefail

GIT_MIN_MAJOR=2
GIT_MIN_MINOR=18
GIT_BUILD_VERSION=2.47.2

need_build=false

if command -v git &>/dev/null; then
    ver=$(git --version | grep -oP '\d+\.\d+\.\d+')
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if (( major < GIT_MIN_MAJOR || (major == GIT_MIN_MAJOR && minor < GIT_MIN_MINOR) )); then
        echo "System git ${ver} is too old (need >= ${GIT_MIN_MAJOR}.${GIT_MIN_MINOR}), building from source..."
        need_build=true
    else
        echo "System git ${ver} is sufficient."
    fi
else
    echo "No git found, building from source..."
    need_build=true
fi

if [ "$need_build" = false ]; then
    exit 0
fi

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl make gcc libssl-dev libcurl4-openssl-dev \
    libexpat1-dev gettext zlib1g-dev autoconf

curl -fsSL "https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_BUILD_VERSION}.tar.gz" -o /tmp/git.tar.gz
tar xzf /tmp/git.tar.gz -C /tmp

make -C "/tmp/git-${GIT_BUILD_VERSION}" prefix=/usr/local -j"$(nproc)" NO_TCLTK=1 NO_PERL=1 all
make -C "/tmp/git-${GIT_BUILD_VERSION}" prefix=/usr/local NO_TCLTK=1 NO_PERL=1 install

# Cleanup build artifacts to save disk
rm -rf "/tmp/git-${GIT_BUILD_VERSION}" /tmp/git.tar.gz

echo "Installed git $(git --version)"
