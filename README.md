# nagios-nrpe-server-ap

Custom Debian/Ubuntu package of the [NRPE](https://github.com/NagiosEnterprises/nrpe)
daemon (`nagios-nrpe-server`), rebuilt with support for command arguments:

- compiled with `--enable-command-args` (`debian/rules`)
- `dont_blame_nrpe=1` in the shipped default `nrpe.cfg`
- `include_dir=/etc/nagios/nrpe.d/` moved before the local config include
  (via `debian/patches/99_update_default_cfg`)

> **Warning:** Allowing clients to pass command arguments is a security risk —
> anyone allowed by `allowed_hosts` can run the defined commands with arbitrary
> arguments. Keep `allowed_hosts` in `/etc/nagios/nrpe.cfg` restricted to your
> monitoring servers and use this only on trusted networks.

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

The script fetches the distribution's `nagios-nrpe` source package, applies
the changes from `scripts/prepare/` and `scripts/patches/`, bumps the version
to `<upstream>-<revision>*1000+<build>` and produces the `.deb` files in the
working directory. Supported flavors are listed in
`.github/supported-releases.txt`.
