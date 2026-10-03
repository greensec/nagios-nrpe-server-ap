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

# the init script only needs the lsb init helpers; they moved from
# lsb-base to sysvinit-utils in 3.05-4, but bullseye/jammy (and the EOL
# overlays) ship earlier versions - keep the dependency unversioned so
# the package stays installable everywhere we publish
sed -i 's/sysvinit-utils (>= 3\.05-4~)/sysvinit-utils/' debian/control

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

# fix stale doc references (default file and doc dir follow the new name)
if [ -f debian/NEWS ]; then
    sed -i "s|/etc/default/${old_pkg}|/etc/default/${new_pkg}|g; s|/usr/share/doc/${old_pkg}|/usr/share/doc/${new_pkg}|g" debian/NEWS
fi

# Debian's init script sources the package's /etc/default file first and the
# ancient /etc/default/nagios-nrpe file second, so a leftover legacy file can
# silently override our defaults (e.g. NRPE_OPTS="-n" would disable TLS).
# Swap the order: legacy file first (compat fallback), our file last.
# The rewrite only runs while the -ap include still precedes the legacy one,
# so re-running this script on a prepared tree is a safe no-op.
init="debian/${new_pkg}.init"
if [ -f "$init" ]; then
    ap_ln=$(awk '/\/etc\/default\/nagios-nrpe-server-ap/{print NR; exit}' "$init")
    leg_ln=$(awk '/\/etc\/default\/nagios-nrpe[^-]/{print NR; exit}' "$init")
    if [ -n "$ap_ln" ] && [ -n "$leg_ln" ] && [ "$ap_ln" -lt "$leg_ln" ]; then
        sed -i '/^# Include nagios-nrpe defaults if available$/{N;N;N;N;N;N;N;N;c\
# we also used to include this file, so if it'"'"'s there\
# we include it as well\
if [ -f /etc/default/nagios-nrpe ]; then\
	. /etc/default/nagios-nrpe\
fi\
\
# Include nagios-nrpe defaults if available\
if [ -f /etc/default/nagios-nrpe-server-ap ] ; then\
	. /etc/default/nagios-nrpe-server-ap\
fi
}' "$init"
        ap_ln=$(awk '/\/etc\/default\/nagios-nrpe-server-ap/{print NR; exit}' "$init")
        leg_ln=$(awk '/\/etc\/default\/nagios-nrpe[^-]/{print NR; exit}' "$init")
        if [ -z "$ap_ln" ] || [ -z "$leg_ln" ] || [ "$leg_ln" -ge "$ap_ln" ]; then
            echo "ERROR: failed to reorder /etc/default includes in $init" >&2
            exit 1
        fi
    fi
fi
