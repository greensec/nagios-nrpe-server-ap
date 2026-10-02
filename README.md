# nagios-nrpe-server-ap

Custom Debian/Ubuntu package of the [NRPE](https://github.com/NagiosEnterprises/nrpe)
daemon (`nagios-nrpe-server`), rebuilt with support for command arguments:

- compiled with `--enable-command-args` (`debian/rules`)
- `dont_blame_nrpe=1` in the shipped default `nrpe.cfg`
- `include_dir=/etc/nagios/nrpe.d/` moved before the local config include
  (via `debian/patches/99_update_default_cfg`)
- upstream fixes released after NRPE 4.1.3 backported
  (`debian/patches/90_upstream_*`): IPv4 long option, remote port debug
  output, memory leaks, config reset on reload, complete SSL reads/writes
  (`ssl_recvall`/`ssl_sendall`), client sockets marked
  non-blocking + close-on-exec so plugin children cannot inherit them,
  `openssl/engine.h` only included for OpenSSL < 3.0, and the
  `configure` C99-vsnprintf probe fixed for GCC >= 14
  (from Fedora/PR https://github.com/NagiosEnterprises/nrpe/pull/273),
  plus selected fixes from upstream 813ca0d/ad44d84
  (`debian/patches/92_upstream_813ca0d_fixes`): ACLs cleared before
  re-parsing `allowed_hosts` (removed hosts kept access after SIGHUP),
  `/0` netmask evaluation fixed (was UB, silently denied everything),
  NUL-termination of the plugin-output buffer in `my_system` (stack
  over-read via `strncat`), `process_metachars` loop condition,
  free-before-`strdup` on config re-parse, `snprintf` truncation check
  in `read_config_dir`, `fd_set` leak, `asprintf` return checks, and
  `ssl_verify_callback` cert-detail logging
- security hardening (`debian/patches/91_security_*`):
  - `buffer_length` of v3/v4 packets is converted with `ntohl()`
    instead of `ntohs()` (upstream bug: the 16-bit truncation made the
    forced string terminator land at `buffer[-1]`)
  - TLS minimum is **TLS 1.2** (`ssl_version=TLSv1.2+` shipped in
    `nrpe.cfg`, code default changed as well) and the default cipher
    list drops `@SECLEVEL=0`, anonymous and export-grade ciphers
    (`ALL:!aNULL:!eNULL:!LOW:!EXP:!RC4:!MD5:@STRENGTH:@SECLEVEL=1` —
    `!SSLv2`/`!SSLv3` ciphers are not selectable at all any more, so
    they need no explicit exclusion)
  - privilege dropping fails closed: an unresolvable `nrpe_user`/
    `nrpe_group` or a failed `setgid`/`setuid`/`initgroups` aborts
    startup, and plugin children exit instead of running as root
    (`initgroups` EPERM stays non-fatal so running the daemon as an
    unprivileged user, e.g. systemd `User=`, still works)
  - the `allowed_hosts` ACL is evaluated before forking where possible,
    so unauthenticated connection floods no longer cost a double-fork
    per connection (DNS ACL entries still resolve in the child)
  - the default `nasty_metachars` blacklist additionally rejects
    `$`, `"`, `#`, `~` (`$IFS` expansion, quote injection, shell
    comments and tilde expansion)
- robustness (`debian/patches/93_security_*`): `include`/`include_dir`
  nesting is bounded at 8 levels (a config cycle previously recursed
  until stack exhaustion), `stat()` failures and empty `include_dir=`
  paths no longer touch uninitialized/out-of-bounds memory, and
  `sendall()` retries `EAGAIN` on the non-blocking client socket so a
  stalled client can't truncate a response
- additional hardening (`debian/patches/94_security_*`): `my_system()`
  no longer performs a wild pointer write on the fork-failure path,
  treats signal-killed plugins as failures instead of possibly
  `STATE_OK`, and checks the output-buffer allocation; non-numeric
  IPv6 prefix lengths in `allowed_hosts` are rejected instead of
  silently becoming `::/0`; privilege dropping resolves the passwd
  entry for `initgroups()` so numeric `nrpe_user` values and a missing
  `nrpe_group` work correctly under the fail-closed policy; and
  `allowed_hosts` is now enforced in inetd mode as well
- static-analyzer pass (`debian/patches/95_security_*`): allocation
  failures no longer silently disable the `nasty_metachars` filter,
  the accept loop's `fd_set` is checked, `conn_check_peer()` refuses
  connections of unknown address families instead of skipping the
  ACL, and its error paths no longer leave a closed descriptor for
  the caller to double-close

> **Warning:** Allowing clients to pass command arguments is a security risk —
> anyone allowed by `allowed_hosts` can run the defined commands with arbitrary
> arguments. Keep `allowed_hosts` in `/etc/nagios/nrpe.cfg` restricted to your
> monitoring servers and use this only on trusted networks.

> **TLS compatibility:** The daemon now requires TLS 1.2 or newer with
> non-anonymous ciphers. Stock `check_nrpe` clients on any still-supported
> distro (OpenSSL >= 1.0.1) negotiate this fine; very old clients or ones
> pinned to TLS 1.0/1.1 will be refused. If you must support those,
> relax `ssl_version`/`ssl_cipher_list` in `nrpe.cfg`.

The binary package is renamed to `nagios-nrpe-server-ap` and declares
`Provides`, `Replaces` and `Conflicts` on `nagios-nrpe-server`: it is a
drop-in replacement, but cannot be installed alongside the stock package.

| What | Path / name |
|------|-------------|
| systemd unit | `nagios-nrpe-server-ap.service` |
| sysvinit script | `/etc/init.d/nagios-nrpe-server-ap` |
| defaults file | `/etc/default/nagios-nrpe-server-ap` |
| main config | `/etc/nagios/nrpe.cfg` |
| config snippets | `/etc/nagios/nrpe.d/*.cfg` |
| daemon binary | `/usr/sbin/nrpe` (runs as `nagios`) |

## Debian/Ubuntu repository

### Currently supported Debian/Ubuntu versions

* bullseye
* bookworm
* trixie
* noble

Packages are built for `amd64`.

### How to add this repository

#### Automatically via script

```bash
wget -O- https://greensec.github.io/nagios-nrpe-server-ap/scripts/add-repository.sh | bash
apt-get install nagios-nrpe-server-ap
```

#### Manually

##### Legacy one-line source

For releases still using the traditional one-line `sources.list` format
(Debian bullseye/bookworm):

```bash
apt-get install wget lsb-release ca-certificates
wget -O /usr/share/keyrings/greensec.github.io-nagios-nrpe-server-ap.key \
    https://greensec.github.io/nagios-nrpe-server-ap/public.key
echo "deb [signed-by=/usr/share/keyrings/greensec.github.io-nagios-nrpe-server-ap.key] https://greensec.github.io/nagios-nrpe-server-ap/repo $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/nagios-nrpe-server-ap.list
apt-get update && apt-get install nagios-nrpe-server-ap
```

##### DEB822 source

For releases using the DEB822 `.sources` format (Debian trixie, Ubuntu noble):

```bash
apt-get install wget lsb-release ca-certificates
wget -O /usr/share/keyrings/greensec.github.io-nagios-nrpe-server-ap.key \
    https://greensec.github.io/nagios-nrpe-server-ap/public.key
cat > /etc/apt/sources.list.d/nagios-nrpe-server-ap.sources <<EOF
Types: deb
URIs: https://greensec.github.io/nagios-nrpe-server-ap/repo
Suites: $(lsb_release -sc)
Components: main
Signed-By: /usr/share/keyrings/greensec.github.io-nagios-nrpe-server-ap.key
EOF
apt-get update && apt-get install nagios-nrpe-server-ap
```

## GitHub releases

Alternatively, download the `.deb` for your distribution directly from the
[GitHub releases](https://github.com/greensec/nagios-nrpe-server-ap/releases)
page and install it with:

```bash
apt-get install ./nagios-nrpe-server-ap_*_amd64.deb
```

## Usage

Define commands with arguments in a snippet under `/etc/nagios/nrpe.d/`, e.g.
`/etc/nagios/nrpe.d/custom.cfg`:

```ini
command[check_disk_root]=/usr/lib/nagios/plugins/check_disk -w $ARG1$ -c $ARG2$ -p /
```

On the monitoring host, call it with `check_nrpe -a`:

```bash
check_nrpe -H <host> -c check_disk_root -a '10%' '5%'
```

Restart after changing the configuration:

```bash
systemctl restart nagios-nrpe-server-ap
```

## Building

Releases are built by GitHub Actions inside containers of the target
distribution (see `.github/workflows/`). Pushing a `v*` tag builds all
supported flavors, creates a GitHub release with the `.deb` files and
publishes them to the APT repository on `gh-pages`.

To build locally, run on a Debian/Ubuntu system (or container) of the
desired flavor:

```bash
./scripts/build.sh        # optional first arg: build number (default: 1)
```

The script fetches the newest `nagios-nrpe` source package published in
Debian unstable (currently 4.1.3) so every supported distro is built from the
same latest upstream release, applies the changes from `scripts/prepare/` and
`scripts/patches/`, bumps the version to
`<upstream>-<revision>*1000+<build>~<codename>1` (e.g. `4.1.3-1001~trixie1`)
and produces the `.deb` files in the working directory. Supported flavors are
listed in `.github/supported-releases.txt`.
