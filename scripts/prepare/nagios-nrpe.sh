#!/bin/bash
set -euo pipefail

old_pkg="nagios-nrpe-server"
new_pkg="nagios-nrpe-server-ap"

sed -i "s/^Package: ${old_pkg}\$/Package: ${new_pkg}/" debian/control
sed -i 's/Conflicts: nagios-nrpe-doc/Conflicts: nagios-nrpe-doc, nagios-nrpe-server/g' debian/control
sed -i 's/--enable-ssl/--enable-ssl --enable-command-args/' debian/rules

# Debian package metadata/install files are named after the binary package.
# If we rename the package in debian/control, these must be renamed too or
# debhelper will skip them (leading to an almost empty package).
for x in debian/${old_pkg}.*; do
    [ -e "$x" ] || continue
    mv "$x" "debian/${new_pkg}${x#debian/${old_pkg}}"
done
