#!/bin/sh
# To add this repository please do:
set -e

if [ "$(whoami)" != "root" ]; then
    SUDO=sudo
fi

KEYRING=/usr/share/keyrings/greensec.github.io-nagios-nrpe-server-ap.key
REPO_URL=https://greensec.github.io/nagios-nrpe-server-ap/repo

${SUDO} apt-get update
${SUDO} apt-get -y install lsb-release ca-certificates wget
${SUDO} wget -O "${KEYRING}" https://greensec.github.io/nagios-nrpe-server-ap/public.key

codename=$(lsb_release -sc)
vendor=$(lsb_release -si | tr '[:upper:]' '[:lower:]')

# apt < 1.1 (e.g. Debian jessie) has no signed-by support in deb lines
# and needs apt-transport-https for https repositories
apt_version="$(apt-get --version | sed -n '1{s/^apt //;s/ .*//;p}')"
apt_major="${apt_version%%.*}"
apt_minor="${apt_version#*.}"; apt_minor="${apt_minor%%.*}"
if [ "${apt_major:-0}" -lt 1 ] || { [ "${apt_major}" -eq 1 ] && [ "${apt_minor:-0}" -lt 1 ]; }; then
    ${SUDO} apt-get -y install apt-transport-https
    ${SUDO} apt-key add "${KEYRING}"
    ${SUDO} rm -f /etc/apt/sources.list.d/nagios-nrpe-server-ap.sources
    echo "deb ${REPO_URL} ${codename} main" | ${SUDO} tee /etc/apt/sources.list.d/nagios-nrpe-server-ap.list >/dev/null
elif [ -f "/etc/apt/sources.list.d/${vendor}.sources" ]; then
    ${SUDO} rm -f /etc/apt/sources.list.d/nagios-nrpe-server-ap.list
    cat <<EOF | ${SUDO} tee /etc/apt/sources.list.d/nagios-nrpe-server-ap.sources >/dev/null
Types: deb
URIs: ${REPO_URL}
Suites: ${codename}
Components: main
Signed-By: ${KEYRING}
EOF
else
    ${SUDO} rm -f /etc/apt/sources.list.d/nagios-nrpe-server-ap.sources
    echo "deb [signed-by=${KEYRING}] ${REPO_URL} ${codename} main" | ${SUDO} tee /etc/apt/sources.list.d/nagios-nrpe-server-ap.list >/dev/null
fi

${SUDO} apt-get update
