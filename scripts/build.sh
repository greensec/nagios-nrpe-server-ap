#!/bin/bash
BUILD="$1"
WORKDIR="${PWD}"
SCRIPT=$(readlink -f "$0")
SCRIPTDIR=$(dirname "${SCRIPT}")

source "$SCRIPTDIR/common.sh"
set -e

if [ -z "${BUILD}" ]; then
    BUILD="1"
elif ! [[ "${BUILD}" =~ ^[0-9]+$ ]]; then
    errorline "BUILD must be a number, got: ${BUILD}"
    exit 1
fi

PACKAGE_NAME="nagios-nrpe"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
SOURCE_SUITE="${SOURCE_SUITE:-unstable}"

statusline "Run apt-get update to download source updates"
cd "${WORKDIR}"
apt-get update

# resolve the newest source package published in Debian so every
# supported distro is built from the same (latest) upstream release
statusline "Resolving latest ${PACKAGE_NAME} source package in Debian ${SOURCE_SUITE}"
stanza=$(wget -qO- "${DEBIAN_MIRROR}/dists/${SOURCE_SUITE}/main/source/Sources.xz" \
    | xz -dc | sed -n "/^Package: ${PACKAGE_NAME}\$/,/^$/p")
BASE_VERSION=$(printf '%s\n' "${stanza}" | sed -n 's/^Version: //p' | head -n1)
SRC_DIRECTORY=$(printf '%s\n' "${stanza}" | sed -n 's/^Directory: //p' | head -n1)
mapfile -t SRC_FILES < <(printf '%s\n' "${stanza}" \
    | awk '/^Files:/{f=1;next} /^[^ \t]/{f=0} f && NF==3 {print $3}')

if [ -z "${BASE_VERSION}" ] || [ -z "${SRC_DIRECTORY}" ] || [ "${#SRC_FILES[@]}" -eq 0 ]; then
    errorline "Failed to resolve latest ${PACKAGE_NAME} source package"
    exit 1
fi

BASE_MAJOR=$(echo "${BASE_VERSION}" | cut -d'-' -f1)
BASE_MINOR=$(echo "${BASE_VERSION}" | cut -d'-' -f2)
statusline "Found ${PACKAGE_NAME} ${BASE_VERSION}"

PACKAGES=("${PACKAGE_NAME}")

for PACKAGE in "${PACKAGES[@]}"; do
    CHECK_VERSION=1
    if [ -d "$SCRIPTDIR/download/${PACKAGE}-${BASE_MAJOR}" ]; then
        statusline "Copy local package ${PACKAGE}"
        cp -a "$SCRIPTDIR/download/${PACKAGE}-${BASE_MAJOR}" .
    elif [ -d "$SCRIPTDIR/download/${PACKAGE}" ]; then
        statusline "Copy local package ${PACKAGE}"
        cp -a "$SCRIPTDIR/download/${PACKAGE}" .
        CHECK_VERSION=0
    elif compgen -G "$SCRIPTDIR/download/${PACKAGE}_${BASE_MAJOR}.orig.tar.*" >/dev/null; then
        for tarball in "$SCRIPTDIR/download/${PACKAGE}_${BASE_MAJOR}".orig.tar.*; do
            statusline "Extracting $(basename "${tarball}")"
            tar xf "${tarball}"
        done

        # the debian tarball must be extracted into the source tree
        # extracted above, not into the working directory.
        srcdir=""
        for d in "${PACKAGE}"-*/; do
            if [ -d "$d" ]; then
                srcdir="${d%/}"
                break
            fi
        done

        for tarball in "$SCRIPTDIR/download/${PACKAGE}_${BASE_MAJOR}"-*.debian.tar.*; do
            [ -e "${tarball}" ] || continue
            if [ -z "${srcdir}" ]; then
                errorline "No ${PACKAGE}-* source directory found for $(basename "${tarball}")"
                exit 1
            fi
            statusline "Extracting $(basename "${tarball}") into ${srcdir}"
            tar xf "${tarball}" -C "${srcdir}"
        done
    else
        statusline "Fetching ${PACKAGE} ${BASE_VERSION}"
        for f in "${SRC_FILES[@]}"; do
            wget -q "${DEBIAN_MIRROR}/${SRC_DIRECTORY}/${f}"
        done
        dsc=$(printf '%s\n' "${SRC_FILES[@]}" | grep '\.dsc$' | head -n1)
        if [ -z "${dsc}" ]; then
            errorline "No .dsc file found for ${PACKAGE} ${BASE_VERSION}"
            exit 1
        fi
        dpkg-source -x "${dsc}"
    fi

    # switch to package
    if [ "$CHECK_VERSION" == "1" ]; then
        cd "${PACKAGE}"-*/
    else
        cd "${PACKAGE}"
    fi

    # install build dependencies declared by the extracted debian/control
    statusline "Install build dependencies"
    missing=$(dpkg-checkbuilddeps 2>&1 | sed -n 's/.*Unmet build dependencies: //p' \
        | tr ',' '\n' \
        | sed -e 's/([^)]*)//g; s/\[[^]]*\]//g; s/|.*//' \
              -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
              -e 's/^debhelper-compat$/debhelper/' | sort -u)
    if [ -n "${missing}" ]; then
        apt-get -y install --no-install-recommends ${missing}
        # fail loudly if some dependency still cannot be satisfied
        dpkg-checkbuilddeps
    fi

    if [ -e "$SCRIPTDIR/prepare/${PACKAGE}.sh" ]; then
        mkdir -p debian
        cp "$SCRIPTDIR/prepare/${PACKAGE}.sh" debian/prepare.sh
        statusline "Running prepare/${PACKAGE}.sh"
        # run in a subshell so its "set -euo pipefail" does not leak into us
        bash ./debian/prepare.sh
    fi

    VERSION=$(dpkg-parsechangelog -l debian/changelog -S Version)
    if [ -z "$VERSION" ]; then
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

    # Debian/Ubuntu revisions can contain non-numeric suffixes
    # (e.g. "1ubuntu3" or "1+deb12u1") which break the arithmetic
    # below; use only the leading numeric part.
    MINOR_NUM="${MINOR%%[^0-9]*}"
    CUSTOM_MINOR=$((${MINOR_NUM:-0}*1000+${BUILD}))

    # dpkg expects the upstream tarball as <pkg>_<upstream-version>.orig.tar.*
    # (no Debian revision, no epoch). Only create it if it is not already
    # present - "apt source" downloads the real one, and repacking the
    # extracted tree would bake already-applied quilt patches into it.
    UPSTREAM="${MAJOR#*:}"
    if ! compgen -G "../${PACKAGE}_${UPSTREAM}.orig.tar.*" >/dev/null; then
        tar -cjf "../${PACKAGE}_${UPSTREAM}.orig.tar.bz2" --exclude=debian --exclude=.pc --exclude-vcs .
    fi
    if [ -d "$SCRIPTDIR/patches/${PACKAGE}" ]; then
        for x in "$SCRIPTDIR/patches/${PACKAGE}"/*; do
            [ -e "${x}" ] || continue
            statusline "Add patch $(basename "${x}") to ${PACKAGE}"
            mkdir -p debian/patches/
            cp -v "${x}" debian/patches/
            basename "${x}" >> debian/patches/series
        done
    fi

    cat <<EOF >debian/changelog.2
${PACKAGE} (${MAJOR}-${CUSTOM_MINOR}) stable; urgency=medium

  * Custom build

 -- Builder <domain@example.com>  $(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')

EOF
    cat debian/changelog >>debian/changelog.2
    mv debian/changelog.2 debian/changelog
    statusline "Start build process"
    DEB_BUILD_OPTIONS="noautodbgsym nocheck nodocs" dpkg-buildpackage -j$(nproc) -d -us -uc -b
    cd ..
done

statusline "FINISHED SUCCESSFULLY!"
