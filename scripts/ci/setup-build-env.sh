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

if [[ -n "${ID}" && -z "${VERSION_CODENAME}" ]]; then
    # EOL Debian releases (e.g. jessie) carry no VERSION_CODENAME; the
    # codename only appears parenthesized in VERSION ("8 (jessie)")
    VERSION_CODENAME="$(sed -n 's/.*(\([^()]*\)).*/\1/p' <<< "${VERSION:-}")"
fi

if [[ -z "${ID}" || -z "${VERSION_CODENAME}" ]]; then
    echo "Could not detect distribution ID or VERSION_CODENAME"
    exit 1
fi

if [[ "${ID}" == "debian" ]]; then
    components="main contrib non-free non-free-firmware"
    mirror="http://deb.debian.org/debian"
    security_mirror="http://deb.debian.org/debian-security"

    if [[ "${VERSION_CODENAME}" == "jessie" || "${VERSION_CODENAME}" == "stretch" ]]; then
        # jessie/stretch are EOL: the debian/eol:* images already point at
        # archive.debian.org, but defensively rewrite any stock entries.
        # The security suite on the archive is named '<codename>/updates'.
        components="main contrib non-free"
        mirror="http://archive.debian.org/debian"
        security_mirror="http://archive.debian.org/debian-security"
        # archived Release files carry an expired Valid-Until (jessie's
        # apt predates the check entirely, so this is harmless there)
        echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99eol-archive
        for list in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
            [[ -f "${list}" ]] || continue
            sed -i -E \
                -e "s#https?://(deb|security|ftp)\.debian\.org/debian-security#${security_mirror}#g" \
                -e 's#https?://(deb|ftp)\.debian\.org/debian#http://archive.debian.org/debian#g' \
                "${list}"
        done
    fi

    if [[ "${VERSION_CODENAME}" == "bullseye" ]]; then
        # bullseye is EOL: the bullseye-security pool was purged from the CDN
        # while its index remains (404s on install), and archive.debian.org
        # has no bullseye-security tree. Use the last good snapshot for
        # security and archive.debian.org for the frozen release.
        components="main contrib non-free"
        mirror="http://archive.debian.org/debian"
        security_mirror="http://snapshot.debian.org/archive/debian-security/20260901T000000Z"
        # the archived Release files carry an expired Valid-Until
        echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99bullseye-archive
        for list in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
            [[ -f "${list}" ]] || continue
            sed -i -E \
                -e "s#https?://(deb|security)\.debian\.org/debian-security#${security_mirror}#g" \
                -e 's#https?://deb\.debian\.org/debian#http://archive.debian.org/debian#g' \
                "${list}"
        done
    fi

    if [[ "${VERSION_CODENAME}" == "jessie" || "${VERSION_CODENAME}" == "stretch" ]]; then
        # EOL security suites live at '<codename>/updates' on the archive
        {
            echo "deb-src ${mirror} ${VERSION_CODENAME} ${components}"
            echo "deb-src ${security_mirror} ${VERSION_CODENAME}/updates ${components}"
        } > /etc/apt/sources.list.d/debian-src.list
    else
        {
            echo "deb-src ${mirror} ${VERSION_CODENAME} ${components}"
            [[ -z "${security_mirror}" ]] || echo "deb-src ${security_mirror} ${VERSION_CODENAME}-security ${components}"
            echo "deb-src ${mirror} ${VERSION_CODENAME}-updates ${components}"
        } > /etc/apt/sources.list.d/debian-src.list
    fi
fi

if [[ "${ID}" == "ubuntu" ]]; then
    {
        echo "deb-src http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME} main restricted universe multiverse"
        echo "deb-src http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-updates main restricted universe multiverse"
        echo "deb-src http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-security main restricted universe multiverse"
    } > /etc/apt/sources.list.d/ubuntu-src.list
fi

apt-get update
apt-get -y install --no-install-recommends \
    ca-certificates \
    dpkg-dev \
    build-essential \
    wget \
    xz-utils
