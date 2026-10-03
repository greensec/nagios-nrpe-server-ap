#!/usr/bin/env bash
#
# Post-build smoke tests: install the freshly built .deb packages inside
# the target container and exercise the security fixes over real TLS.
#
#   1. malformed-octet ACL entry is rejected (98_security_acl_ipv4_octet)
#   2. SIGHUP reload applies a new allowed_hosts (prefork ACL check)
#   3. all-'!' command buffer returns a response (97_security_strtok_null)
#   4. TLS floor is enforced: TLS1.2 succeeds, TLS1.0/1.1 are refused
#      (91_security_tls_hardening)
#   5. end-to-end check via the built check_nrpe plugin
#
# Probe exit codes (scripts/test/nrpe_probe.py):
#   0 valid NRPE response, 2 connection denied/reset, 3 invalid/empty

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${HERE}/nrpe_probe.py"
HOST=127.0.0.1
PORT=5666
CFG=/etc/nagios/nrpe.cfg
PASS=0
FAIL=0

say()  { printf '[smoke] %s\n' "$*"; }
ok()   { say "PASS: $*"; PASS=$((PASS + 1)); }
fail() { say "FAIL: $*"; FAIL=$((FAIL + 1)); }

export DEBIAN_FRONTEND=noninteractive

# keep the postinst from launching the service; no init in containers
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update -qq
# adduser is a Pre-Depends of the server package; dpkg -i alone cannot
# satisfy it, so install it (and the test deps) up front
apt-get install -y --no-install-recommends python3 openssl adduser >/dev/null

say "installing built packages"
dpkg -i ./nagios-nrpe-server-ap_*.deb ./nagios-nrpe-plugin_*.deb \
    || { apt-get -f install -y && \
         dpkg -i ./nagios-nrpe-server-ap_*.deb ./nagios-nrpe-plugin_*.deb; }

NRPE_BIN="$(command -v nrpe || true)"
PLUGIN="$(find /usr/lib/nagios/plugins /usr/lib*/nagios/plugins -name check_nrpe 2>/dev/null | head -1)"
[ -n "${NRPE_BIN}" ] || { say "nrpe binary not found"; exit 1; }
[ -n "${PLUGIN}" ]  || { say "check_nrpe plugin not found"; exit 1; }
say "nrpe=${NRPE_BIN} check_nrpe=${PLUGIN}"

# --- daemon configuration -------------------------------------------------
sed -i \
    -e "s/^allowed_hosts=.*/allowed_hosts=127.0.0.4294967297/" \
    -e "s/^dont_blame_nrpe=.*/dont_blame_nrpe=1/" \
    "${CFG}"
grep -q '^dont_blame_nrpe=' "${CFG}" || echo 'dont_blame_nrpe=1' >> "${CFG}"
grep -q '^command\[test_ok\]=' "${CFG}" || \
    echo 'command[test_ok]=/bin/echo TESTOK' >> "${CFG}"

PIDFILE="$(sed -n 's/^pid_file=\s*\(.*\)/\1/p' "${CFG}" | head -1)"
PIDFILE="${PIDFILE:-/var/run/nagios/nrpe.pid}"
mkdir -p "$(dirname "${PIDFILE}")"
rm -f "${PIDFILE}"

"${NRPE_BIN}" -c "${CFG}" -d
sleep 1
nrpe_pid() { cat "${PIDFILE}" 2>/dev/null || true; }
kill -0 "$(nrpe_pid)" || { say "daemon failed to start"; exit 1; }

cleanup() {
    local p; p="$(nrpe_pid)"
    [ -n "${p}" ] && kill "${p}" 2>/dev/null || true
}
trap cleanup EXIT

wait_port() {
    for _ in $(seq 1 20); do
        (exec 3<>"/dev/tcp/${HOST}/${PORT}") 2>/dev/null && {
            exec 3>&- 3<&-; return 0; }
        sleep 0.5
    done
    return 1
}
wait_port || { say "daemon not listening"; exit 1; }

# --- test 1: malformed-octet ACL entry must not wrap ----------------------
say "test: allowed_hosts=127.0.0.4294967297 rejects 127.0.0.1"
python3 "${PROBE}" "${HOST}" "${PORT}" test_ok
rc=$?
if [ "${rc}" -eq 0 ]; then
    fail "wrap-octet ACL entry was treated as 127.0.0.1 (response received)"
elif [ "${rc}" -eq 3 ]; then
    fail "connection accepted but no valid response"
else
    ok "malformed ACL entry rejected (rc=${rc})"
fi

# --- test 2: SIGHUP reload applies new allowed_hosts ----------------------
say "test: SIGHUP reload picks up allowed_hosts=127.0.0.1"
sed -i "s/^allowed_hosts=.*/allowed_hosts=127.0.0.1/" "${CFG}"
kill -HUP "$(nrpe_pid)"
sleep 1
wait_port || { fail "daemon did not come back after SIGHUP"; }
out="$(python3 "${PROBE}" "${HOST}" "${PORT}" test_ok 2>/dev/null)"
rc=$?
if [ "${rc}" -eq 0 ] && [ "${out}" = "TESTOK" ]; then
    ok "post-reload query returned '${out}'"
else
    fail "post-reload query rc=${rc} out='${out}'"
fi

# --- test 3: all-'!' command buffer must not crash the child --------------
# the request is invalid (no command name), so the daemon bails without
# responding; the regression is the child crashing on strdup(NULL) -
# assert the daemon survives and still serves the next request
say "test: '!'-only command buffer is rejected without killing the daemon"
python3 "${PROBE}" "${HOST}" "${PORT}" '!' >/dev/null 2>&1
sleep 0.5
kill -0 "$(nrpe_pid)" || fail "daemon died during '!' test"
out="$(python3 "${PROBE}" "${HOST}" "${PORT}" test_ok 2>/dev/null)"
rc=$?
if [ "${rc}" -eq 0 ] && [ "${out}" = "TESTOK" ]; then
    ok "daemon healthy after '!' buffer"
else
    fail "daemon unhealthy after '!' buffer (rc=${rc} out='${out}')"
fi

# --- test 4: TLS floor ----------------------------------------------------
# @SECLEVEL is OpenSSL >= 1.1.0 syntax; detect support once
if openssl ciphers 'ALL:@SECLEVEL=0' >/dev/null 2>&1; then
    S_CLIENT_CIPHER='ALL:@SECLEVEL=0'
else
    S_CLIENT_CIPHER='ALL'
fi

tls_handshake() {
    # $1 = s_client proto flag; returns 0 if a handshake completed.
    # A completed handshake leaves a cipher line naming a real cipher;
    # failures print 'Cipher is (NONE)' (1.0.x) or 'Cipher    : 0000' (3.x)
    local out
    out="$(echo | timeout 10 openssl s_client \
        -connect "${HOST}:${PORT}" "$1" \
        -cipher "${S_CLIENT_CIPHER}" </dev/null 2>&1 || true)"
    grep -E 'Cipher is |Cipher[[:space:]]+:' <<< "${out}" \
        | grep -vqE '\(NONE\)|: 0000'
}

say "test: TLS1.2 handshake succeeds"
if tls_handshake -tls1_2; then
    ok "TLS1.2 negotiated"
else
    fail "TLS1.2 handshake failed"
fi

for proto in tls1 tls1_1; do
    say "test: ${proto} handshake is refused"
    if ! openssl s_client -help 2>&1 | grep -q -- "-${proto}"; then
        say "SKIP: client openssl cannot offer ${proto}"
        continue
    fi
    if tls_handshake "-${proto}"; then
        fail "${proto} negotiated (floor not enforced)"
    else
        ok "${proto} refused"
    fi
done

# --- test 5: end-to-end check_nrpe plugin ---------------------------------
say "test: check_nrpe plugin returns TESTOK"
out="$("${PLUGIN}" -H "${HOST}" -p "${PORT}" -c test_ok -t 10 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ] && [ "${out}" = "TESTOK" ]; then
    ok "check_nrpe returned '${out}'"
else
    fail "check_nrpe rc=${rc} out='${out}'"
fi

say "result: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
