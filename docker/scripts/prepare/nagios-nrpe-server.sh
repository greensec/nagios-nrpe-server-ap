#!/bin/bash
sed -i 's,Package: nagios-nrpe-server,Package: nagios-nrpe-server-ap,g' debian/control
sed -i 's/Conflicts: nagios-nrpe-doc/Conflicts: nagios-nrpe-doc, nagios-nrpe-server/g' debian/control
sed -i 's/--enable-ssl/--enable-ssl --enable-command-args/' debian/rules
