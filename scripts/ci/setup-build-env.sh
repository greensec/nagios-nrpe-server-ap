#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if [[ ! -r /etc/os-release ]]; then
    echo "Missing /etc/os-release; cannot detect distribution"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

ID="${ID:-}"
VERSION_CODENAME="${VERSION_CODENAME:-}"

if [[ -z "${ID}" || -z "${VERSION_CODENAME}" ]]; then
    echo "Could not detect distribution ID or VERSION_CODENAME"
    exit 1
fi

if [[ "${ID}" == "debian" ]]; then
    if [[ "${VERSION_CODENAME}" == "bullseye" ]]; then
        components="main contrib non-free"
    else
        components="main non-free-firmware"
    fi

    {
        echo "deb-src http://deb.debian.org/debian ${VERSION_CODENAME} ${components}"
        echo "deb-src http://deb.debian.org/debian-security ${VERSION_CODENAME}-security ${components}"
        echo "deb-src http://deb.debian.org/debian ${VERSION_CODENAME}-updates ${components}"
    } > /etc/apt/sources.list.d/debian-src.list
fi

if [[ "${ID}" == "ubuntu" ]]; then
    {
        echo "deb-src http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME} main restricted universe multiverse"
        echo "deb-src http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-updates main restricted universe multiverse"
        echo "deb-src http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-security main restricted universe multiverse"
    } > /etc/apt/sources.list.d/ubuntu-src.list
fi

apt-get update
apt-get -y install \
    wget \
    ca-certificates \
    gnupg \
    quilt \
    vim \
    debhelper \
    build-essential \
    lsb-release \
    dh-python \
    devscripts
