#!/usr/bin/env python3
"""NRPE v4 client probe for CI smoke tests.

Sends a single query packet over TLS and classifies the outcome:

  ok      - a valid NRPE response packet was received
  denied  - the connection was rejected/reset (ACL or handshake failure)
  invalid - something else arrived that is not a valid response

Kept compatible with Python >= 3.4 (jessie ships 3.4.2): no f-strings,
no ssl.PROTOCOL_TLS_CLIENT requirement.
"""

import socket
import ssl
import struct
import sys
import zlib

QUERY_PACKET = 1
RESPONSE_PACKET = 2
NRPE_PACKET_VERSION_4 = 4

# int16 version, int16 type, u_int32 crc32, int16 result,
# int16 alignment, int32 buffer_length
V4_HEADER = "!hhIhhi"


def build_query(buf):
    pkt = struct.pack(V4_HEADER, NRPE_PACKET_VERSION_4, QUERY_PACKET,
                      0, 0, 0, len(buf)) + buf
    crc = zlib.crc32(pkt) & 0xFFFFFFFF
    return struct.pack(V4_HEADER, NRPE_PACKET_VERSION_4, QUERY_PACKET,
                       crc, 0, 0, len(buf)) + buf


def ssl_context():
    proto = getattr(ssl, "PROTOCOL_TLS_CLIENT",
                    getattr(ssl, "PROTOCOL_TLS",
                            getattr(ssl, "PROTOCOL_TLSv1_2", None)))
    ctx = ssl.SSLContext(proto)
    if hasattr(ctx, "check_hostname"):
        ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    # widest client cipher set so the daemon decides what is acceptable;
    # @SECLEVEL only exists on OpenSSL >= 1.1.0, and the cert-less
    # default mode needs anonymous-DH (aNULL) ciphers offered
    for ciphers in ("ALL:@SECLEVEL=0", "ALL"):
        try:
            ctx.set_ciphers(ciphers)
            break
        except ssl.SSLError:
            continue
    return ctx


def recv_all(sock, timeout):
    sock.settimeout(timeout)
    data = b""
    try:
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    except (socket.timeout, ssl.SSLError):
        pass
    return data


def response_buffer(resp):
    """Return the response payload if resp is a valid v4 response."""
    if len(resp) < 16:
        return None
    ver, ptype, _crc, _res, _align, blen = struct.unpack(
        V4_HEADER, resp[:16])
    if ver != NRPE_PACKET_VERSION_4 or ptype != RESPONSE_PACKET:
        return None
    if blen <= 0 or 16 + blen > len(resp):
        return None
    return resp[16:16 + blen]


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: nrpe_probe.py HOST PORT BUFFER_TEXT\n")
        return 64

    host, port = sys.argv[1], int(sys.argv[2])
    buf = sys.argv[3].encode("utf-8") + b"\0"

    ctx = ssl_context()
    last_err = None
    for _attempt in range(3):
        try:
            raw = socket.create_connection((host, port), 5)
            sock = ctx.wrap_socket(raw)
            break
        except (socket.error, ssl.SSLError) as e:
            last_err = e
            import time
            time.sleep(0.5)
    else:
        sys.stderr.write("connect/handshake failed: {0}\n".format(last_err))
        return 2  # denied/unreachable

    try:
        sock.sendall(build_query(buf))
        resp = recv_all(sock, 10)
    except (socket.error, ssl.SSLError) as e:
        sys.stderr.write("send/recv failed: {0}\n".format(e))
        return 2
    finally:
        try:
            sock.close()
        except Exception:
            pass

    payload = response_buffer(resp)
    if payload is None:
        sys.stderr.write("no valid response ({0} bytes)\n".format(len(resp)))
        return 3  # invalid/empty

    sys.stdout.write(payload.split(b"\0")[0].decode("utf-8", "replace"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
