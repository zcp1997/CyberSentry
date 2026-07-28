# CyberSentry

[English](./README_EN.md) | 简体中文

安全、可重复执行的 Debian/Ubuntu 部署脚本，用于安装：

- Cowrie SSH/Telnet 蜜罐
- Fail2ban SSH 防护
- Cowrie systemd 服务
- 仅针对 Cowrie 日志的 logrotate 规则

此 fork 修复了原脚本与 Cowrie 3.x 不兼容的问题，并移除了会影响整台 VPS 的高风险操作。

## 安全边界

安装器**不会**：

- 克隆 Cowrie 不稳定的 `main` 分支
- 修改 `/etc/apt/sources.list` 或执行发行版升级
- 替换系统默认 `python3`
- 修改系统时区
- 修改 SSH 端口、认证方式或密钥
- 自动启用或修改 UFW
- 清理 `/var/log` 中其他服务的日志
- 删除无法识别的 `/opt/cowrie`

旧版或失败的 Cowrie 目录会原样保留为：

```text
/opt/cowrie.legacy-YYYYMMDD_HHMMSS-PID
```

其中的旧配置不会自动合并到新安装；请在新服务验证成功后手工比对。对于本 fork 已识别的受管安装，脚本才会备份当前配置并协调三个受管键。

## 系统要求

- Debian 或 Ubuntu
- systemd
- Root 权限
- Python 3.10+

通常建议使用 Debian 12+ 或 Ubuntu 22.04+。安装器不会通过 PPA、跨发行版软件源或 `update-alternatives` 强行替换 Python。

## 安装

建议先下载和检查，再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/zcp1997/CyberSentry/main/install.sh
less install.sh
sudo bash install.sh
```

默认配置：

- Cowrie：固定安装 PyPI `3.0.0`
- Cowrie 状态目录：`/opt/cowrie`
- Cowrie 监听端口：`2222/tcp`
- 蜜罐主机名：`debian-s31343`
- 单个下载大小限制：1 MiB
- Cowrie 日志轮转：每日，保留 30 份
- Fail2ban：24 小时封禁、30 分钟检测窗口、3 次失败

## 自定义参数

通过环境变量覆盖默认值：

```bash
sudo \
  COWRIE_VERSION=3.0.0 \
  COWRIE_HOSTNAME=my-honeypot \
  COWRIE_SSH_PORT=2222 \
  COWRIE_DOWNLOAD_LIMIT=1048576 \
  LOG_RETENTION_DAYS=30 \
  bash install.sh
```

约束：

- `COWRIE_SSH_PORT` 必须是 `1024-65535`
- `COWRIE_HOSTNAME` 最长 64 字符，只允许字母、数字、点、下划线和连字符
- `COWRIE_VERSION` 应固定为经过验证的 Cowrie 发行版本

## 安装逻辑

1. 安装 Cowrie 官方所需的 Python/编译依赖和 Fail2ban。
2. 验证系统 Python 为 3.10+，但不修改系统 Python。
3. 在 `/opt/cowrie/cowrie-env` 创建独立 venv。
4. 使用 `pip install cowrie==固定版本` 安装 Cowrie。
5. 首次安装时运行 `cowrie init`；已有配置会先备份，再将 `hostname`、`download_limit_size` 和 `listen_endpoints` 三个受管键协调为本次环境变量或默认值，其他配置保持不变。
6. 将 venv、配置和安装目录设为 root 只读，仅允许 `cowrie` 写入 `/opt/cowrie/var`。
7. 通过 `/opt/cowrie/cowrie-env/bin/cowrie start -n` 启动 systemd 服务。
8. 等待服务稳定并确认端口实际监听，同时验证 Fail2ban 的 `sshd` jail。

## 端口与防火墙

安装器不自动修改 SSH 或 UFW，避免把远程 VPS 锁死。

如果已经启用 UFW，请手动确认 Cowrie 端口已放行：

```bash
ufw allow 2222/tcp comment 'Cowrie Honeypot'
ufw status
```

Cowrie 默认监听 2222，而不是公网标准 SSH 端口 22。若要捕获访问 22 的流量，应先将真实 SSH 安全迁移到其他端口并从另一个会话验证，再单独配置 nftables/iptables 的 `22 -> 2222` 转发。

## 文件位置

- Cowrie 配置：`/opt/cowrie/etc/cowrie.cfg`
- Cowrie 日志：`/opt/cowrie/var/log/cowrie/`
- Cowrie venv：`/opt/cowrie/cowrie-env/`
- systemd 服务：`/etc/systemd/system/cowrie.service`
- Fail2ban 配置：`/etc/fail2ban/jail.d/cybersentry.local`
- logrotate：`/etc/logrotate.d/cowrie`
- 配置备份：`/root/config_backups/`

## 常用命令

```bash
systemctl status cowrie fail2ban
systemctl restart cowrie
journalctl -u cowrie -f
tail -f /opt/cowrie/var/log/cowrie/cowrie.log
fail2ban-client status sshd
```

## 从原脚本失败状态恢复

如果原脚本停在：

```text
cp: cannot stat 'etc/cowrie.cfg.dist': No such file or directory
```

直接运行此 fork 的新安装器即可。旧的 `/opt/cowrie` 不会被删除，而会被移动到带时间戳的 `.legacy-*` 目录。确认新服务及所需旧日志、配置均无误后，再自行决定是否清理旧目录。

## 本地静态验证

验证不会运行安装器：

```bash
bash -n install.sh
python3 -m unittest -v tests/test_installer.py
```

## 许可证

MIT License，沿用原项目许可。
