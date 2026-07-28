# CyberSentry

[简体中文](./README.md) | English

A safer, repeatable Debian/Ubuntu installer for:

- Cowrie SSH/Telnet honeypot
- Fail2ban SSH protection
- A hardened Cowrie systemd service
- Log rotation scoped only to Cowrie logs

This fork fixes the original installer's incompatibility with Cowrie 3.x and removes host-wide destructive behavior.

## Safety boundaries

The installer does **not**:

- Clone Cowrie's moving `main` branch
- Rewrite APT repositories or perform a distribution upgrade
- Replace the system `python3`
- Change the system timezone
- Change SSH ports, authentication, or keys
- Enable or modify UFW automatically
- Delete unrelated files under `/var/log`
- Delete an unrecognised `/opt/cowrie` directory

An old or incomplete Cowrie directory is preserved as:

```text
/opt/cowrie.legacy-YYYYMMDD_HHMMSS-PID
```

Its configuration is not merged automatically into the replacement. Compare it manually after the new service is verified. Backup-and-reconcile behavior applies only to installations already recognized as managed by this fork.

## Requirements

- Debian or Ubuntu
- systemd
- Root privileges
- Python 3.10+

Debian 12+ or Ubuntu 22.04+ is recommended. The installer will not use a PPA, cross-release repositories, or `update-alternatives` to force a different Python version.

## Install

Download and inspect the script before running it:

```bash
curl -fsSLO https://raw.githubusercontent.com/zcp1997/CyberSentry/main/install.sh
less install.sh
sudo bash install.sh
```

Defaults:

- Cowrie: pinned PyPI release `3.0.0`
- State directory: `/opt/cowrie`
- Listen port: `2222/tcp`
- Honeypot hostname: `debian-s31343`
- Per-download limit: 1 MiB
- Cowrie log rotation: daily, 30 rotations
- Fail2ban: 24-hour ban, 30-minute find window, 3 retries

## Configuration overrides

Use environment variables to override defaults:

```bash
sudo \
  COWRIE_VERSION=3.0.0 \
  COWRIE_HOSTNAME=my-honeypot \
  COWRIE_SSH_PORT=2222 \
  COWRIE_DOWNLOAD_LIMIT=1048576 \
  LOG_RETENTION_DAYS=30 \
  bash install.sh
```

Constraints:

- `COWRIE_SSH_PORT` must be between `1024-65535`
- `COWRIE_HOSTNAME` is limited to 64 letters, digits, dots, underscores, and hyphens
- `COWRIE_VERSION` should remain pinned to a tested Cowrie release

## Installation design

1. Install Cowrie's Python/build dependencies and Fail2ban.
2. Require Python 3.10+ without changing the system interpreter.
3. Create an isolated venv at `/opt/cowrie/cowrie-env`.
4. Install Cowrie with `pip install cowrie==<pinned version>`.
5. Run `cowrie init` for a new state directory. Existing configuration is backed up, then the managed `hostname`, `download_limit_size`, and `listen_endpoints` keys are reconciled to the requested environment values or defaults; other settings remain unchanged.
6. Make the venv, configuration, and install tree root-owned and read-only, leaving only `/opt/cowrie/var` writable by `cowrie`.
7. Start systemd with `/opt/cowrie/cowrie-env/bin/cowrie start -n`.
8. Require a stable service interval, verify the listening socket, and confirm the Fail2ban `sshd` jail.

## Ports and firewall

The installer deliberately leaves SSH and UFW unchanged to avoid locking users out of remote VPS hosts.

If UFW is already enabled, allow the Cowrie port manually:

```bash
ufw allow 2222/tcp comment 'Cowrie Honeypot'
ufw status
```

Cowrie listens on 2222 by default, not the public SSH port 22. To capture port-22 traffic, first move the real SSH daemon to another port and verify access from a second session. Configure the `22 -> 2222` nftables/iptables redirect separately afterward.

## Paths

- Cowrie config: `/opt/cowrie/etc/cowrie.cfg`
- Cowrie logs: `/opt/cowrie/var/log/cowrie/`
- Cowrie venv: `/opt/cowrie/cowrie-env/`
- systemd unit: `/etc/systemd/system/cowrie.service`
- Fail2ban config: `/etc/fail2ban/jail.d/cybersentry.local`
- logrotate config: `/etc/logrotate.d/cowrie`
- Config backups: `/root/config_backups/`

## Service commands

```bash
systemctl status cowrie fail2ban
systemctl restart cowrie
journalctl -u cowrie -f
tail -f /opt/cowrie/var/log/cowrie/cowrie.log
fail2ban-client status sshd
```

## Recovering from the original installer failure

If the original installer stopped with:

```text
cp: cannot stat 'etc/cowrie.cfg.dist': No such file or directory
```

Run this fork's installer. It preserves the failed `/opt/cowrie` tree in a timestamped `.legacy-*` directory instead of deleting it. Remove that backup only after checking the new service and recovering any old logs or configuration you need.

## Static verification

These checks do not run the installer:

```bash
bash -n install.sh
python3 -m unittest -v tests/test_installer.py
```

## License

MIT License, inherited from the original project.
