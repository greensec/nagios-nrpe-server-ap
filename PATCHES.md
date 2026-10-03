# Patches

`scripts/patches/nagios-nrpe/` is copied into `debian/patches/` at build
time by `scripts/build.sh` and applied on top of Debian's
`nagios-nrpe 4.1.3-1` source package (which itself carries
`02_nrpe.cfg_local-include_support_nrpe.d`, `07_warn_ssloption` and
`ssl-rpath`).

Naming scheme:

| Prefix | Meaning |
|--------|---------|
| `90_upstream_*`, `92_upstream_*` | Backports of upstream post-4.1.3 commits |
| `9[1-6]_security_*` | Vendor security/robustness fixes (this project) |
| `99_update_default_cfg` | Shipped configuration defaults |
| `legacy_*` | EOL-only; applied **only** with a `debian.<codename>/` packaging overlay (jessie/stretch) |

## Upstream backports

| Patch | What it fixes |
|-------|---------------|
| `90_upstream_configure_c99_vsnprintf` | `AC_TRY_RUN` probe lacked includes/main() proto → silently fell back to bundled `snprintf` on GCC ≥14 (implicit decl = error). From Fedora's packaging. |
| `90_upstream_debug_remote_port` | Debug logs printed `sin_port` in network byte order and re-derived the IPv6 host string. (4083cff8) |
| `90_upstream_fix_ipv4_long_option` | `--ipv4` was registered as `"4"` → long option rejected. (8bf4595) |
| `90_upstream_memory_leaks` | Leaks in ACL parsing, env setup, listener creation and SSL connection handling; frees `nasty_metachars`/`keep_env_vars` on config reload. (b4ca91f) |
| `90_upstream_openssl_engine_include` | `engine.h` only included for OpenSSL < 3.0 (API removed in 3.0). (c3ee87f et al.) |
| `90_upstream_reload_reset_config` | SIGHUP reload kept values for options removed from nrpe.cfg; adds `reset_config()`. (825d310) |
| `90_upstream_socket_nonblock_cloexec` | `FD_CLOEXEC`+`O_NONBLOCK` on the accepted client socket — plugin children no longer inherit it (which could keep connections open). (bf4afc8) |
| `90_upstream_ssl_sendall_recvall` | `SSL_read`/`SSL_write` can short-transfer; loops with `select()` until packet complete or timeout. Fixes truncated/missing responses on non-blocking sockets. (846a01a) |
| `92_upstream_813ca0d_fixes` | Surgical extraction of upstream `813ca0d`/`ad44d84`: `0.0.0.0/0` ACL silently broken by UB shift (`~0u << 32` evaluated to `/32`); stale ACLs survived SIGHUP reload (now cleared); `my_system` `strncat` on unterminated `read()` buffer (stack over-read); `process_metachars` comma-operator loop condition; reload leaks; `fd_set` realloc/leak; `asprintf` checks; `ssl_verify_callback` `\|\|`→`&&` (valid certs weren't detail-logged). |

## Vendor security and robustness fixes

| Patch | What it fixes |
|-------|---------------|
| `91_security_buffer_length_ntohl` | v3/v4 `buffer_length` (32-bit) was read with `ntohs()` → truncated to 16 bits; the forced terminator landed at `buffer[-1]`. Now `ntohl()`. |
| `91_security_tls_hardening` | Code default `TLSv1_plus`+`ALL:!MD5:@STRENGTH:@SECLEVEL=0` → `TLSv1_2_plus`+`ALL:!aNULL:!eNULL:!LOW:!EXP:!RC4:!MD5:@STRENGTH:@SECLEVEL=1`; shipped cfg sets `ssl_version=TLSv1.2+`. |
| `91_security_failclosed_privdrop` | `drop_privileges()` only warned on unresolvable user/group or failed `setuid`/`setgid` → daemon and plugin children ran as root. Now fatal. |
| `91_security_acl_prefork` | `allowed_hosts` is now evaluated in the parent before the double-fork, so unauthenticated connection floods don't cost two forks each. DNS ACLs still resolve in the child. |
| `91_security_metachars_default` | Default `nasty_metachars` blacklist extended with `$ " # ~` (IFS expansion, quote injection, comment truncation, tilde expansion). |
| `93_security_config_include_depth` | `include=`/`include_dir=` recursed unboundedly → stack exhaustion on config cycles; now bounded at 8. Also: `stat()` failure left `buf` uninitialized; `include_dir=` empty path read `[-1]`. |
| `93_security_sendall_eagain` | `sendall()` broke on `EAGAIN` → non-blocking socket + stalled client = truncated response. Retries within `socket_timeout`. |
| `94_security_my_system_fixes` | `*output[i]` precedence bug wrote a NUL through a wild pointer on fork-failure; unchecked `waitpid`/`WIFEXITED` → signal-killed plugins reported `STATE_OK` (now `STATE_CRITICAL`); unchecked output `calloc` → NULL deref. |
| `94_security_acl_ipv6_mask` | IPv6 prefix parsed with `atoi()` → `::/typo` silently became `::/0` (allow-all). Digit-validated, bad entries refused. |
| `94_security_inetd_acl` | `conn_check_peer()` only ran in the daemon accept loop → `allowed_hosts` was never enforced in inetd mode. Now enforced. |
| `94_security_privdrop_numeric_user` | `initgroups()` got the raw config string → numeric `nrpe_user`/missing `nrpe_group` failed under the fail-closed policy. Resolves via `getpwuid`, clears supplementary groups when unresolvable (no root-group residue). |
| `95_security_failclosed_paths` | `process_metachars` `strdup` unchecked → alloc failure silently **disabled metachar filtering** (now fatal); `fd_set` calloc unchecked; `conn_check_peer` skipped ACL for non-INET families (AF_UNIX under a super-server walked past `allowed_hosts` — now refused); close-then-return double-close; defensive `nptr`/`nptr6` init. |
| `95_security_privdrop_pw_init` | `pw` uninitialized on the numeric-UID path of `drop_privileges` — garbage pointer read by the initgroups resolver (fixes the numeric-user path). |
| `96_security_alloc_robustness` | `clean_environ` uninitialized `var` → first `realloc` freed a wild pointer; unchecked reallocs; `trim()` `isspace` on signed char (UB on high-bit bytes) + missing NULL guards; unchecked ACL token alloc; `check_nrpe` unchecked packet callocs, NULL-deref on malformed reply, and unterminated `%s` print of wire data. |
| `97_security_strtok_null` | With `--enable-command-args`, a request buffer of only `!` separators made `strtok()` return NULL → `strdup(NULL)` → NULL-deref crash of the connection child (found by libFuzzer; stock builds unaffected). |

## Package defaults

| Patch | What it does |
|-------|--------------|
| `99_update_default_cfg` | Ships `dont_blame_nrpe=1` (paired with `--enable-command-args` added to `debian/rules` by `scripts/prepare/nagios-nrpe.sh`) and moves `include_dir=/etc/nagios/nrpe.d/` next to the related options. |

## legacy_* — EOL distribution compatibility

Applied **only** when `debian.<codename>/` overlay is in use
(jessie/stretch); never part of modern builds.

| Patch | What it does |
|-------|--------------|
| `legacy_compat` | Fixes `#include "dh.h"` resolving to the system `<openssl/dh.h>` — harmless on OpenSSL ≥1.1.0 (`AUTO_SSL_DH` skips it) but a link failure on 1.0.x, where the static `get_dh2048()` is actually compiled in. The TLS floor is **not** relaxed on EOL builds: 1.0.1/1.1.0 both implement TLS 1.2, so `ssl_version=TLSv1.2+` stays (admins can lower to `TLSv1+` for pre-1.2 clients). |

## Deliberately not backported

- **`813ca0d` full `my_system` rewrite** (426-line parent/child IO split) — high backport risk; its exploitable part (the over-read) was fixed surgically in `92_upstream_813ca0d_fixes`, and the pipe deadlock it prevents is already covered by the `O_NONBLOCK` backport.
- **`ad44d84` `check_nrpe` client-side bits** — the plugin deb is a build byproduct, not published.
- Test infra, AIX/LibreSSL support — not relevant to this package.
