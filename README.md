# nagios-nrpe-server-ap

Custom Debian/Ubuntu package of the [NRPE](https://github.com/NagiosEnterprises/nrpe)
daemon (`nagios-nrpe-server`), rebuilt with support for command arguments:

- compiled with `--enable-command-args` (`debian/rules`)
- `dont_blame_nrpe=1` in the shipped default `nrpe.cfg`
- `include_dir=/etc/nagios/nrpe.d/` moved before the local config include
  (via `debian/patches/99_update_default_cfg`)
- upstream fixes released after NRPE 4.1.3 backported
  (`debian/patches/90_upstream_*`, `92_upstream_*`)
- several rounds of security and robustness fixes on top
  (`debian/patches/9[1-6]_security_*`): TLS 1.2 minimum + hardened
  cipher list, fail-closed privilege dropping, `allowed_hosts`
  enforcement before forking and in inetd mode, an extended default
  metachar blacklist, bounded `include`/`include_dir` recursion,
  EAGAIN-tolerant `sendall`, strict IPv6 mask parsing, and a set of
  memory-safety fixes found by `-fanalyzer`

The full catalog with per-patch details lives in [PATCHES.md](PATCHES.md).

> **Warning:** Allowing clients to pass command arguments is a security risk —
> anyone allowed by `allowed_hosts` can run the defined commands with arbitrary
> arguments. Keep `allowed_hosts` in `/etc/nagios/nrpe.cfg` restricted to your
> monitoring servers and use this only on trusted networks.

> **TLS compatibility:** On the current distributions the daemon requires
> TLS 1.2 or newer with non-anonymous ciphers. Stock `check_nrpe` clients
> on any still-supported distro (OpenSSL >= 1.0.1) negotiate this fine;
> very old clients or ones pinned to TLS 1.0/1.1 will be refused. If you
> must support those, relax `ssl_version`/`ssl_cipher_list` in `nrpe.cfg`.
>
> The **jessie and stretch** builds are exceptions: they ship
> `ssl_version=TLSv1+` (TLS 1.0 and later, the upstream default) for
> compatibility with the monitoring clients of that era. The hardened
> cipher list is still in effect; raise the floor with
> `ssl_version=TLSv1.2+` if all your clients support it.

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
* jammy
* noble
* stretch *(EOL — relaxed TLS defaults, see note above)*
* jessie *(EOL — relaxed TLS defaults, see note above)*

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
listed in `.github/supported-releases.txt` (EOL releases use their
`debian/eol:*` container images).

### EOL distributions

Debian jessie and stretch predate the modern packaging toolchain
(`debhelper-compat 13`, OpenSSL 1.1.1, `signed-by` apt sources). They are
built from dedicated packaging overlays instead: `scripts/build.sh`
detects the host codename and, when a matching `debian.<codename>/`
directory exists at the repository root, swaps it in place of the
upstream `debian/` tree. The overlays (`debian.jessie/` → debhelper 9 +
`--with systemd`, `debian.stretch/` → debhelper 10) keep the same file
layout and let `scripts/prepare/` perform the package rename as usual.

Distribution-specific source patches live in `scripts/patches/` with a
`legacy_` prefix (currently `legacy_compat`: relaxed TLS floor plus a
`dh.h` include fix needed on OpenSSL 1.0.x) and are only applied when a
packaging overlay is in use — modern builds never see them.
