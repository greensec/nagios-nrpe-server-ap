#!/bin/bash
BUILD="$1"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd $SCRIPT_DIR
source common.sh
set -e

if [ -z $BUILD ]; then
    BUILD="1"
fi

PACKAGE_NAME="nagios-nrpe"

statusline "Run apt-get update to download source updates"
apt-get update

apt-get -y build-dep nagios-nrpe
apt-get -y install nagios-nrpe-server

BASE_VERSION=$(dpkg-query -f '${Version}' -W "nagios-nrpe-server")
if [ -z $BASE_VERSION ]; then
    errorline "Failed to fetch ${PACKAGE_NAME} base verison!"
    exit 1
fi

BASE_MAJOR=$(echo "${BASE_VERSION}" | cut -d'-' -f1)
BASE_MINOR=$(echo "${BASE_VERSION}" | cut -d'-' -f2)
statusline "Found ${PACKAGE_NAME} ${BASE_VERSION}"

mkdir -p $BHOME/build
PACKAGES=("${PACKAGE_NAME}")

cd $BHOME/build
for PACKAGE in ${PACKAGES[@]}; do
    CHECK_VERSION=1
    if [ -d $BHOME/download/${PACKAGE}-${BASE_MAJOR} ]; then
        statusline "Copy local package ${PACKAGE}"
        cp -a $BHOME/download/${PACKAGE}-${BASE_MAJOR} .
    elif [ -d $BHOME/download/${PACKAGE} ]; then
        statusline "Copy local package ${PACKAGE}"
        cp -a $BHOME/download/${PACKAGE} .
        CHECK_VERSION=0
    elif compgen -G "$BHOME/download/${PACKAGE}_${BASE_MAJOR}.orig.tar.*" >/dev/null; then
        if compgen -G "$BHOME/download/${PACKAGE}_${BASE_MAJOR}.orig.tar.bz2" >/dev/null; then
            statusline "Extracting ${PACKAGE}_${BASE_MAJOR}.orig.tar.bz2"
            tar xjf $BHOME/download/${PACKAGE}_${BASE_MAJOR}.orig.tar.bz2
        fi
        if compgen -G "$BHOME/download/${PACKAGE}_${BASE_MAJOR}.orig.tar.xz" >/dev/null; then
            statusline "Extracting ${PACKAGE}_${BASE_MAJOR}.orig.tar.xz"
            tar xJf $BHOME/download/${PACKAGE}_${BASE_MAJOR}.orig.tar.xz
        fi

        if compgen -G "$BHOME/download/${PACKAGE}_${BASE_MAJOR}-*.debian.tar.bz2" >/dev/null; then
            statusline "Extracting ${PACKAGE}_${BASE_MAJOR}-*.debian.tar.bz2"
            tar xjf $BHOME/download/${PACKAGE}_${BASE_MAJOR}-*.debian.tar.bz2
        fi

        if compgen -G "$BHOME/download/${PACKAGE}_${BASE_MAJOR}-*.debian.tar.xz" >/dev/null; then
            statusline "Extracting ${PACKAGE}_${BASE_MAJOR}-*.debian.tar.xz"
            tar xJf $BHOME/download/${PACKAGE}_${BASE_MAJOR}-*.debian.tar.xz
        fi
    else
        statusline "Fetching ${PACKAGE}"
        apt source -y ${PACKAGE}
    fi

    # switch to package
    if [ "$CHECK_VERSION" == "1" ]; then
        cd ${PACKAGE}-*
    else
        cd ${PACKAGE}
    fi

    if [ -e $BHOME/prepare/${PACKAGE}.sh ]; then
        mkdir -p debian
        cp $BHOME/prepare/${PACKAGE}.sh debian/prepare.sh
        . ./debian/prepare.sh
    fi

    VERSION=$(head -n1 debian/changelog | grep -o -E '^.*\((.*)\)' | sed -e 's,.*(,,' -e 's,),,')
    if [ -z $VERSION ]; then
        errorline "Failed to fetch package version!"
        exit 1
    fi

    MAJOR=$(echo "${VERSION}" | cut -d'-' -f1)
    MINOR=$(echo "${VERSION}" | cut -d'-' -f2)
    statusline "Found ${PACKAGE} ${VERSION}"
    if [ "$CHECK_VERSION" == "1" ]; then
        if [ "$MAJOR" != "$BASE_MAJOR" ]; then
            errorline "Major $BASE_MAJOR does not match package major $MAJOR"
            exit 1
        fi

        if [ "$MINOR" != "$BASE_MINOR" ]; then
            errorline "WARN: Minor $BASE_MINOR does not match package minor $MINOR"
        fi
    else
        MINOR="1"
    fi

    CUSTOM_MINOR=$((${MINOR}*1000+${BUILD}))
    tar -cjf ../${PACKAGE}_${MAJOR}-${CUSTOM_MINOR}.orig.tar.bz2 --exclude=debian .
    if [ -d $BHOME/patches/${PACKAGE} ]; then
        for x in $BHOME/patches/${PACKAGE}/*; do
            statusline "Add patch $(basename ${x}) to ${PACKAGE}"
            mkdir -p debian/patches/
            cp -v $x debian/patches/
            echo $(basename $x) >> debian/patches/series
        done
    fi

    cat <<EOF >debian/changelog.2
${PACKAGE} (${MAJOR}-${CUSTOM_MINOR}) stable; urgency=medium

  * Custom build

 -- Builder <domain@example.com>  $(date '+%a, %d %b %Y %H:%M:%S %z')

EOF
    cat debian/changelog >>debian/changelog.2
    mv debian/changelog.2 debian/changelog
    statusline "Start build process"
    DEB_BUILD_OPTIONS="noautodbgsym nocheck nodocs" dpkg-buildpackage -j$(nproc) -d -us -b
    cd ..
done

statusline "FINISHED SUCCESSFULLY!"
