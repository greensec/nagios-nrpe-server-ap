#!/bin/bash
set -euo pipefail

old_pkg="nagios-nrpe-server"
new_pkg="nagios-nrpe-server-ap"

sed -i "s/^Package: ${old_pkg}\$/Package: ${new_pkg}/" debian/control
if ! grep -q "^Package: ${new_pkg}\$" debian/control; then
    echo "ERROR: could not find 'Package: ${old_pkg}' in debian/control" >&2
    exit 1
fi

# The renamed package ships the same files as the original daemon package,
# so it must conflict with it. It also provides/replaces it so packages
# depending on ${old_pkg} still resolve. Scope the edit to the renamed
# stanza only: e.g. nagios-nrpe-plugin has a Conflicts: line too which
# must not be touched.
stanza_re="/^Package: ${new_pkg}\$/,/^\$/"
if sed -n "${stanza_re}p" debian/control | grep -q '^Conflicts:'; then
    sed -i "${stanza_re}s/^Conflicts: /Conflicts: ${old_pkg}, /" debian/control
else
    sed -i "/^Package: ${new_pkg}\$/a Conflicts: ${old_pkg}" debian/control
fi
sed -i "/^Package: ${new_pkg}\$/a Replaces: ${old_pkg}\nProvides: ${old_pkg}" debian/control

# some flavors (e.g. Ubuntu) already build with --enable-command-args.
if ! grep -q -- '--enable-command-args' debian/rules; then
    sed -i 's/--enable-ssl/--enable-ssl --enable-command-args/' debian/rules
    if ! grep -q -- '--enable-command-args' debian/rules; then
        echo "ERROR: failed to add --enable-command-args in debian/rules" >&2
        exit 1
    fi
fi

# Debian package metadata/install files are named after the binary package.
# If we rename the package in debian/control, these must be renamed too or
# debhelper will skip them (leading to an almost empty package). References
# to the old package name inside these files (e.g. the service's
# EnvironmentFile or the init script's /etc/default path) must be updated
# as well, otherwise they silently point at nonexistent files.
for x in debian/${old_pkg}.*; do
    [ -e "$x" ] || continue
    new="debian/${new_pkg}${x#debian/${old_pkg}}"
    mv "$x" "$new"
    sed -i "s/${old_pkg}/${new_pkg}/g" "$new"
done
