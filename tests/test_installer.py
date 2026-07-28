from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text(encoding="utf-8")
README_ZH = (ROOT / "README.md").read_text(encoding="utf-8")
README_EN = (ROOT / "README_EN.md").read_text(encoding="utf-8")
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
LICENSE = ROOT / "LICENSE"


class InstallerContractTests(unittest.TestCase):
    @staticmethod
    def function_body(name: str) -> str:
        match = re.search(
            rf"^{re.escape(name)}\(\) \{{\n(.*?)^\}}$",
            INSTALLER,
            re.MULTILINE | re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"installer function {name!r} not found")
        return match.group(1)

    @staticmethod
    def run_embedded_config_updater(
        content: str, section: str, key: str, value: str
    ) -> str:
        match = re.search(
            r"python3 - \"\$file\" \"\$section\" \"\$key\" \"\$value\" <<'PY'\n"
            r"(.*?)\nPY",
            INSTALLER,
            re.DOTALL,
        )
        if match is None:
            raise AssertionError("embedded Cowrie config updater not found")

        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "cowrie.cfg"
            config.write_text(content, encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    match.group(1),
                    str(config),
                    section,
                    key,
                    value,
                ],
                check=True,
            )
            return config.read_text(encoding="utf-8")

    def test_uses_pinned_pypi_cowrie_workflow(self) -> None:
        self.assertRegex(
            INSTALLER,
            r'COWRIE_VERSION="\$\{COWRIE_VERSION:-3\.0\.0\}"',
        )
        self.assertIn('cowrie==${COWRIE_VERSION}', INSTALLER)
        self.assertRegex(INSTALLER, r'\bcowrie(?:"|\$\{[^}]+\})? init\b|"\$COWRIE_BIN" init')
        self.assertNotIn("git clone https://github.com/cowrie/cowrie", INSTALLER)
        self.assertNotIn("pip install -r requirements.txt", INSTALLER)

    def test_requires_python_310_without_replacing_system_python(self) -> None:
        self.assertIn("sys.version_info >= (3, 10)", INSTALLER)
        self.assertNotIn("update-alternatives", INSTALLER)
        self.assertNotIn("python3.7", INSTALLER)
        self.assertNotIn("deadsnakes", INSTALLER)

    def test_does_not_perform_release_upgrade_or_rewrite_apt_sources(self) -> None:
        self.assertNotRegex(INSTALLER, r"apt(?:-get)?\s+upgrade")
        self.assertNotIn("/etc/apt/sources.list", INSTALLER)
        self.assertNotIn("apt remove --purge", INSTALLER)

    def test_preserves_unrecognised_existing_cowrie_directory(self) -> None:
        preservation = self.function_body("preserve_unrecognised_installation")
        self.assertNotRegex(preservation, r"\brm\s+-rf\b")
        self.assertIn("legacy-", preservation)
        self.assertRegex(preservation, r'\bmv\s+"\$COWRIE_INSTALL_DIR"')

    def test_existing_install_requires_managed_root_owned_version_markers(self) -> None:
        classifier = self.function_body("is_managed_installation")
        self.assertIn("CYBERSENTRY_MARKER", classifier)
        self.assertIn("COWRIE_VERSION", classifier)
        self.assertRegex(classifier, r"root_owned|root-owned|%u")
        self.assertIn("METADATA", classifier)
        self.assertIn("preserve_unrecognised_installation", INSTALLER)

    def test_cowrie_account_is_dedicated_and_legacy_shape_is_hardened(self) -> None:
        account = self.function_body("ensure_cowrie_account")
        self.assertIn("groupadd --system cowrie", account)
        self.assertIn("/home/cowrie", account)
        self.assertIn("$COWRIE_INSTALL_DIR", account)
        self.assertIn("usermod", account)
        self.assertIn("--shell", account)
        self.assertIn("--gid cowrie", account)
        self.assertIn("nologin", account)

    def test_managed_tree_is_read_only_except_var(self) -> None:
        hardening = self.function_body("harden_cowrie_permissions")
        self.assertRegex(hardening, r"chown .*root:root")
        self.assertRegex(hardening, r"chown .*cowrie.*var|chown .*var.*cowrie")
        self.assertIn("go-w", hardening)
        self.assertIn("reject_symlink", INSTALLER)

        unit = self.function_body("configure_cowrie_service")
        self.assertIn("ProtectSystem=strict", unit)
        read_write_paths = re.findall(r"^ReadWritePaths=(.*)$", unit, re.MULTILINE)
        self.assertEqual(read_write_paths, ["${COWRIE_INSTALL_DIR}/var"])

    def test_root_managed_writes_are_guarded_against_symlinks(self) -> None:
        self.assertIn("reject_symlink_components", INSTALLER)
        self.assertIn("atomic_install_from_stdin", INSTALLER)
        for destination in (
            "FAIL2BAN_CONFIG",
            "COWRIE_SERVICE",
            "COWRIE_LOGROTATE",
            "COWRIE_CONFIG",
        ):
            self.assertRegex(
                INSTALLER,
                rf'reject_symlink_components "\${destination}"|'
                rf'atomic_install_from_stdin "\${destination}"',
            )

    def test_transaction_rolls_back_every_managed_file_and_legacy_move(self) -> None:
        self.assertRegex(INSTALLER, r"trap ['\"].*rollback.*EXIT")
        rollback = self.function_body("rollback_changes")
        for destination in (
            "FAIL2BAN_CONFIG",
            "COWRIE_SERVICE",
            "COWRIE_LOGROTATE",
            "COWRIE_CONFIG",
        ):
            self.assertIn(destination, rollback)
        self.assertIn("LEGACY_BACKUP", rollback)
        self.assertIn("systemctl restart fail2ban", rollback)

    def test_backups_are_unique_mode_preserving_and_include_logrotate(self) -> None:
        backup = self.function_body("backup_file")
        self.assertIn("mktemp", backup)
        self.assertIn("cp -a", backup)
        self.assertNotIn("chmod 0600", backup)
        transaction = self.function_body("begin_transaction")
        self.assertIn("COWRIE_LOGROTATE", transaction)

    def test_systemd_runs_installed_virtualenv_entrypoint(self) -> None:
        self.assertIn("ExecStart=${COWRIE_BIN} start -n", INSTALLER)
        self.assertIn("Environment=PATH=${COWRIE_VENV}/bin:", INSTALLER)
        self.assertNotIn("bin/cowrie start -n", INSTALLER)
        self.assertIn("Restart=on-failure", INSTALLER)
        self.assertNotIn("Restart=always", INSTALLER)

    def test_transaction_restores_service_enablement_and_legacy_activity(self) -> None:
        begin = self.function_body("begin_transaction")
        rollback = self.function_body("rollback_changes")
        self.assertIn("systemctl is-enabled --quiet fail2ban", begin)
        self.assertIn("systemctl is-enabled --quiet cowrie", begin)
        self.assertIn("FAIL2BAN_WAS_ENABLED", rollback)
        self.assertIn("COWRIE_WAS_ENABLED", rollback)
        self.assertRegex(rollback, r"systemctl (?:enable|disable) fail2ban")
        self.assertRegex(rollback, r"systemctl (?:enable|disable) cowrie")
        legacy_restore = rollback.index('mv "$LEGACY_BACKUP" "$COWRIE_INSTALL_DIR"')
        active_restart = rollback.rindex("COWRIE_WAS_ACTIVE")
        self.assertGreater(active_restart, legacy_restore)

    def test_fail2ban_uses_all_validated_effective_ssh_ports(self) -> None:
        ports = self.function_body("get_effective_ssh_ports")
        self.assertIn("sshd -T", ports)
        self.assertNotIn("${port:-22}", ports)
        self.assertRegex(ports, r"paste .*[,]|printf.*,")

        fail2ban = self.function_body("configure_fail2ban")
        generated = re.search(
            r'atomic_install_from_stdin "\$FAIL2BAN_CONFIG".*?<<EOF\n(.*?)\nEOF',
            fail2ban,
            re.DOTALL,
        )
        self.assertIsNotNone(generated)
        assert generated is not None
        self.assertNotIn("[DEFAULT]", generated.group(1))
        self.assertRegex(
            generated.group(1),
            re.compile(r"\[sshd\].*bantime.*findtime.*maxretry", re.DOTALL),
        )
        self.assertIn("fail2ban-client status sshd", fail2ban)

    def test_cowrie_health_requires_settling_and_listening_socket(self) -> None:
        health = self.function_body("start_and_verify_cowrie")
        self.assertIn("COWRIE_SETTLE_SECONDS", health)
        self.assertIn("systemctl is-active --quiet cowrie", health)
        self.assertRegex(health, r"\bss\s+-H\s+-ltn")
        self.assertIn("COWRIE_SSH_PORT", health)

    def test_log_management_is_scoped_to_cowrie(self) -> None:
        self.assertIn("/etc/logrotate.d/cowrie", INSTALLER)
        self.assertNotRegex(INSTALLER, r"find\s+/var/log")
        self.assertNotIn("cleanup_logs.sh", INSTALLER)

    def test_installer_does_not_modify_ssh_or_enable_ufw(self) -> None:
        self.assertNotRegex(INSTALLER, r"sed\s+-i.*sshd_config")
        self.assertNotRegex(INSTALLER, r"ufw\s+--force\s+enable")
        self.assertNotRegex(INSTALLER, r"systemctl\s+restart\s+ssh")

    def test_documentation_points_to_the_fork_and_current_python(self) -> None:
        for readme in (README_ZH, README_EN):
            self.assertIn("zcp1997/CyberSentry", readme)
            self.assertIn("Python 3.10+", readme)
            self.assertNotIn("CurtisLu1/CyberSentry/main/install.sh", readme)
            self.assertNotIn("Python 3.9+", readme)

    def test_config_values_are_validated_as_decimal(self) -> None:
        self.assertRegex(INSTALLER, r"COWRIE_SSH_PORT.*1024.*65535|validate_port")
        self.assertIn("COWRIE_HOSTNAME", INSTALLER)
        self.assertIn("COWRIE_DOWNLOAD_LIMIT", INSTALLER)
        validation = self.function_body("validate_settings")
        self.assertIn("10#$COWRIE_SSH_PORT", validation)
        self.assertIn("10#$COWRIE_DOWNLOAD_LIMIT", validation)
        self.assertIn("10#$LOG_RETENTION_DAYS", validation)

    def test_docs_describe_reconciliation_not_full_preservation(self) -> None:
        self.assertRegex(
            README_EN,
            re.compile(r"back(?:ed)? up.*reconcil", re.IGNORECASE | re.DOTALL),
        )
        self.assertIn("备份", README_ZH)
        self.assertIn("协调", README_ZH)

    def test_repository_contains_full_mit_license(self) -> None:
        self.assertTrue(LICENSE.is_file())
        text = LICENSE.read_text(encoding="utf-8")
        self.assertIn("MIT License", text)
        self.assertIn("Permission is hereby granted, free of charge", text)
        self.assertIn('THE SOFTWARE IS PROVIDED "AS IS"', text)

    def test_checkout_action_is_pinned_to_a_commit(self) -> None:
        references = re.findall(r"actions/checkout@([^\s]+)", CI)
        self.assertTrue(references)
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in references))

    def test_config_updater_replaces_commented_key_once(self) -> None:
        updated = self.run_embedded_config_updater(
            "[ssh]\n# listen_endpoints = tcp:2222:interface=0.0.0.0\n",
            "ssh",
            "listen_endpoints",
            "tcp:3022:interface=0.0.0.0",
        )
        self.assertEqual(
            updated,
            "[ssh]\nlisten_endpoints = tcp:3022:interface=0.0.0.0\n",
        )

    def test_config_updater_adds_missing_section(self) -> None:
        updated = self.run_embedded_config_updater(
            "[honeypot]\nhostname = test\n",
            "ssh",
            "listen_endpoints",
            "tcp:2222:interface=0.0.0.0",
        )
        self.assertIn("[ssh]\nlisten_endpoints = tcp:2222:interface=0.0.0.0\n", updated)

    def test_config_updater_handles_missing_final_newline(self) -> None:
        updated = self.run_embedded_config_updater(
            "[ssh]\n# another setting without a final newline",
            "ssh",
            "listen_endpoints",
            "tcp:2222:interface=0.0.0.0",
        )
        self.assertIn(
            "# another setting without a final newline\n"
            "listen_endpoints = tcp:2222:interface=0.0.0.0\n",
            updated,
        )


if __name__ == "__main__":
    unittest.main()
