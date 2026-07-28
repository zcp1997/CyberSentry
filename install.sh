#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# CyberSentry safe installer
# Cowrie is installed from a pinned PyPI release. SSH, UFW, APT sources,
# timezone, and the system Python are deliberately left unchanged.

COWRIE_VERSION="${COWRIE_VERSION:-3.0.0}"
COWRIE_INSTALL_DIR="/opt/cowrie"
COWRIE_VENV="${COWRIE_INSTALL_DIR}/cowrie-env"
COWRIE_BIN="${COWRIE_VENV}/bin/cowrie"
COWRIE_PYTHON="${COWRIE_VENV}/bin/python"
COWRIE_CONFIG="${COWRIE_INSTALL_DIR}/etc/cowrie.cfg"
COWRIE_HOSTNAME="${COWRIE_HOSTNAME:-debian-s31343}"
COWRIE_SSH_PORT="${COWRIE_SSH_PORT:-2222}"
COWRIE_DOWNLOAD_LIMIT="${COWRIE_DOWNLOAD_LIMIT:-1048576}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
COWRIE_SETTLE_SECONDS="${COWRIE_SETTLE_SECONDS:-8}"
FAIL2BAN_READY_TIMEOUT="${FAIL2BAN_READY_TIMEOUT:-30}"

BACKUP_DIR="/root/config_backups"
FAIL2BAN_CONFIG="/etc/fail2ban/jail.d/cybersentry.local"
COWRIE_SERVICE="/etc/systemd/system/cowrie.service"
COWRIE_LOGROTATE="/etc/logrotate.d/cowrie"
CYBERSENTRY_MARKER="${COWRIE_INSTALL_DIR}/.cybersentry-managed"
METADATA="${COWRIE_INSTALL_DIR}/.cybersentry-cowrie-version"

MISSING_BACKUP="__CYBERSENTRY_MISSING__"
LAST_BACKUP=""
FAIL2BAN_BACKUP=""
SERVICE_BACKUP=""
LOGROTATE_BACKUP=""
CONFIG_BACKUP=""
LEGACY_BACKUP=""
TRANSACTION_ACTIVE=0
TRANSACTION_COMMITTED=0
INSTALL_WAS_MANAGED=0
FAIL2BAN_WAS_ACTIVE=0
COWRIE_WAS_ACTIVE=0
FAIL2BAN_WAS_ENABLED=0
COWRIE_WAS_ENABLED=0

log() {
    printf '[CyberSentry] %s\n' "$*"
}

warn() {
    printf '[CyberSentry] 警告：%s\n' "$*" >&2
}

die() {
    printf '[CyberSentry] 错误：%s\n' "$*" >&2
    exit 1
}

on_error() {
    printf '[CyberSentry] 安装在第 %s 行失败。正在退出并回滚本次受管变更。\n' "$1" >&2
}
trap 'on_error "$LINENO"' ERR
trap 'rollback_changes "$?"' EXIT

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 权限运行此脚本"
}

check_platform() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "仅支持 Debian/Ubuntu；当前系统为 ${ID:-unknown}" ;;
    esac
    [[ -d /run/systemd/system ]] || die "此安装器需要 systemd"
}

validate_settings() {
    [[ "$COWRIE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9.-]+)?$ ]] \
        || die "COWRIE_VERSION 格式无效：$COWRIE_VERSION"
    [[ "$COWRIE_HOSTNAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        || die "COWRIE_HOSTNAME 只能包含字母、数字、点、下划线和连字符，最长 64 字符"

    [[ "$COWRIE_SSH_PORT" =~ ^[0-9]+$ ]] || die "COWRIE_SSH_PORT 必须是十进制整数"
    [[ "$COWRIE_DOWNLOAD_LIMIT" =~ ^[0-9]+$ ]] || die "COWRIE_DOWNLOAD_LIMIT 必须是十进制整数"
    [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "LOG_RETENTION_DAYS 必须是十进制整数"
    [[ "$COWRIE_SETTLE_SECONDS" =~ ^[0-9]+$ ]] || die "COWRIE_SETTLE_SECONDS 必须是十进制整数"
    [[ "$FAIL2BAN_READY_TIMEOUT" =~ ^[0-9]+$ ]] || die "FAIL2BAN_READY_TIMEOUT 必须是十进制整数"

    COWRIE_SSH_PORT=$((10#$COWRIE_SSH_PORT))
    COWRIE_DOWNLOAD_LIMIT=$((10#$COWRIE_DOWNLOAD_LIMIT))
    LOG_RETENTION_DAYS=$((10#$LOG_RETENTION_DAYS))
    COWRIE_SETTLE_SECONDS=$((10#$COWRIE_SETTLE_SECONDS))
    FAIL2BAN_READY_TIMEOUT=$((10#$FAIL2BAN_READY_TIMEOUT))

    ((COWRIE_SSH_PORT >= 1024 && COWRIE_SSH_PORT <= 65535)) \
        || die "COWRIE_SSH_PORT 必须在 1024-65535 之间"
    ((COWRIE_DOWNLOAD_LIMIT > 0)) || die "COWRIE_DOWNLOAD_LIMIT 必须大于 0"
    ((LOG_RETENTION_DAYS > 0)) || die "LOG_RETENTION_DAYS 必须大于 0"
    ((COWRIE_SETTLE_SECONDS >= 3 && COWRIE_SETTLE_SECONDS <= 60)) \
        || die "COWRIE_SETTLE_SECONDS 必须在 3-60 之间"
    ((FAIL2BAN_READY_TIMEOUT >= 5 && FAIL2BAN_READY_TIMEOUT <= 120)) \
        || die "FAIL2BAN_READY_TIMEOUT 必须在 5-120 之间"
}

reject_symlink_components() {
    local path="$1"
    local current=""
    local component
    local -a components=()

    IFS='/' read -r -a components <<< "$path"
    [[ "$path" == /* ]] && current="/"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current="${current%/}/${component}"
        [[ ! -L "$current" ]] || die "拒绝跟随符号链接：$current"
    done
}

backup_file() {
    local source="$1"
    LAST_BACKUP="$MISSING_BACKUP"

    [[ -e "$source" || -L "$source" ]] || return 0
    reject_symlink_components "$source"
    [[ -f "$source" ]] || die "受管路径不是普通文件：$source"

    install -d -m 0700 "$BACKUP_DIR"
    LAST_BACKUP="$(mktemp "${BACKUP_DIR}/$(basename "$source").bak.XXXXXX")"
    cp -a -- "$source" "$LAST_BACKUP"
    log "已备份 $source -> $LAST_BACKUP"
}

restore_file() {
    local destination="$1"
    local backup="$2"

    reject_symlink_components "$destination"
    if [[ "$backup" == "$MISSING_BACKUP" ]]; then
        rm -f -- "$destination"
        return 0
    fi
    [[ -n "$backup" && -f "$backup" ]] || return 0
    cp -a -- "$backup" "$destination"
}

atomic_install_from_stdin() {
    local destination="$1"
    local mode="$2"
    local owner="$3"
    local group="$4"
    local parent temporary

    reject_symlink_components "$destination"
    parent="$(dirname "$destination")"
    [[ -d "$parent" && ! -L "$parent" ]] || die "目标目录无效：$parent"
    temporary="$(mktemp "${parent}/.$(basename "$destination").tmp.XXXXXX")"
    cat > "$temporary"
    chown "$owner:$group" "$temporary"
    chmod "$mode" "$temporary"
    mv -fT -- "$temporary" "$destination"
}

begin_transaction() {
    backup_file "$FAIL2BAN_CONFIG"
    FAIL2BAN_BACKUP="$LAST_BACKUP"
    backup_file "$COWRIE_SERVICE"
    SERVICE_BACKUP="$LAST_BACKUP"
    backup_file "$COWRIE_LOGROTATE"
    LOGROTATE_BACKUP="$LAST_BACKUP"
    backup_file "$COWRIE_CONFIG"
    CONFIG_BACKUP="$LAST_BACKUP"

    if systemctl is-active --quiet fail2ban; then
        FAIL2BAN_WAS_ACTIVE=1
    fi
    if systemctl is-active --quiet cowrie; then
        COWRIE_WAS_ACTIVE=1
    fi
    if systemctl is-enabled --quiet fail2ban; then
        FAIL2BAN_WAS_ENABLED=1
    fi
    if systemctl is-enabled --quiet cowrie; then
        COWRIE_WAS_ENABLED=1
    fi
    TRANSACTION_ACTIVE=1
}

rollback_changes() {
    local status="${1:-1}"
    local failed_path

    if [[ "$status" -eq 0 || "$TRANSACTION_ACTIVE" -ne 1 || "$TRANSACTION_COMMITTED" -eq 1 ]]; then
        return 0
    fi

    trap - ERR EXIT
    set +e
    warn "安装失败，恢复本次修改前的受管配置"
    systemctl stop cowrie >/dev/null 2>&1 || true

    restore_file "$FAIL2BAN_CONFIG" "$FAIL2BAN_BACKUP"
    restore_file "$COWRIE_SERVICE" "$SERVICE_BACKUP"
    restore_file "$COWRIE_LOGROTATE" "$LOGROTATE_BACKUP"
    restore_file "$COWRIE_CONFIG" "$CONFIG_BACKUP"
    if [[ "$INSTALL_WAS_MANAGED" -ne 1 ]] \
        && [[ -e "$COWRIE_INSTALL_DIR" || -L "$COWRIE_INSTALL_DIR" ]]; then
        failed_path="${COWRIE_INSTALL_DIR}.failed-$(date '+%Y%m%d_%H%M%S')-$$"
        mv "$COWRIE_INSTALL_DIR" "$failed_path" 2>/dev/null || true
        warn "失败的新安装保留在：$failed_path"
    fi

    if [[ -n "$LEGACY_BACKUP" && -e "$LEGACY_BACKUP" && ! -e "$COWRIE_INSTALL_DIR" ]]; then
        mv "$LEGACY_BACKUP" "$COWRIE_INSTALL_DIR" || true
        warn "已恢复原 Cowrie 目录：$COWRIE_INSTALL_DIR"
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    if [[ "$FAIL2BAN_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable fail2ban >/dev/null 2>&1 || true
    else
        systemctl disable fail2ban >/dev/null 2>&1 || true
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client -t >/dev/null 2>&1 || true
        systemctl restart fail2ban >/dev/null 2>&1 || true
        [[ "$FAIL2BAN_WAS_ACTIVE" -eq 1 ]] || systemctl stop fail2ban >/dev/null 2>&1 || true
    fi

    if [[ "$COWRIE_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable cowrie >/dev/null 2>&1 || true
    else
        systemctl disable cowrie >/dev/null 2>&1 || true
    fi
    if [[ "$COWRIE_WAS_ACTIVE" -eq 1 ]]; then
        systemctl restart cowrie >/dev/null 2>&1 || true
    else
        systemctl stop cowrie >/dev/null 2>&1 || true
    fi

    return 0
}

install_dependencies() {
    log "更新软件包索引并安装必要依赖（不会执行系统升级）"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        build-essential \
        ca-certificates \
        fail2ban \
        iproute2 \
        libffi-dev \
        libssl-dev \
        logrotate \
        python3 \
        python3-dev \
        python3-pip \
        python3-systemd \
        python3-venv

    python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
        || die "Cowrie ${COWRIE_VERSION} 需要 Python 3.10+；本脚本不会替换系统 Python，请升级发行版后重试"
    log "Python 版本：$(python3 --version 2>&1)"
}

ensure_cowrie_account() {
    local entry home

    getent group cowrie >/dev/null 2>&1 || groupadd --system cowrie
    if ! id -u cowrie >/dev/null 2>&1; then
        useradd --system --gid cowrie --home-dir "$COWRIE_INSTALL_DIR" --shell /usr/sbin/nologin cowrie
        log "已创建 cowrie 系统用户"
        return 0
    fi

    entry="$(getent passwd cowrie)" || die "无法读取 cowrie 用户信息"
    IFS=':' read -r _ _ _ _ _ home _ <<< "$entry"
    case "$home" in
        /home/cowrie|"$COWRIE_INSTALL_DIR") ;;
        *) die "已存在名为 cowrie 的非预期账户（home=$home），拒绝接管" ;;
    esac

    usermod --home "$COWRIE_INSTALL_DIR" --shell /usr/sbin/nologin --gid cowrie cowrie
    log "已验证并加固 cowrie 专用账户"
}

is_managed_installation() {
    local actual_version root_owned

    [[ -d "$COWRIE_INSTALL_DIR" && ! -L "$COWRIE_INSTALL_DIR" ]] || return 1
    [[ -f "$CYBERSENTRY_MARKER" && ! -L "$CYBERSENTRY_MARKER" ]] || return 1
    [[ -f "$METADATA" && ! -L "$METADATA" ]] || return 1
    [[ -f "$COWRIE_CONFIG" && ! -L "$COWRIE_CONFIG" ]] || return 1
    [[ -x "$COWRIE_BIN" && ! -L "$COWRIE_BIN" ]] || return 1
    [[ "$(<"$METADATA")" == "$COWRIE_VERSION" ]] || return 1

    root_owned=1
    for path in "$COWRIE_INSTALL_DIR" "$CYBERSENTRY_MARKER" "$METADATA" "$COWRIE_CONFIG" "$COWRIE_BIN"; do
        [[ "$(stat -c '%u' "$path")" -eq 0 ]] || root_owned=0
    done
    [[ "$root_owned" -eq 1 ]] || return 1

    actual_version="$($COWRIE_PYTHON -c 'from importlib.metadata import version; print(version("cowrie"))' 2>/dev/null)" \
        || return 1
    [[ "$actual_version" == "$COWRIE_VERSION" ]]
}

preserve_unrecognised_installation() {
    [[ -e "$COWRIE_INSTALL_DIR" || -L "$COWRIE_INSTALL_DIR" ]] || return 0
    is_managed_installation && return 0

    if [[ -d "$COWRIE_INSTALL_DIR" && ! -L "$COWRIE_INSTALL_DIR" ]] \
        && [[ -z "$(find "$COWRIE_INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        return 0
    fi

    LEGACY_BACKUP="${COWRIE_INSTALL_DIR}.legacy-$(date '+%Y%m%d_%H%M%S')-$$"
    systemctl stop cowrie 2>/dev/null || true
    mv "$COWRIE_INSTALL_DIR" "$LEGACY_BACKUP"
    warn "检测到非受管、旧版或不完整 Cowrie，已完整保留到 $LEGACY_BACKUP"
}

create_cowrie_environment() {
    if [[ "$INSTALL_WAS_MANAGED" -eq 1 ]]; then
        log "已验证受管 Cowrie ${COWRIE_VERSION}，跳过重复安装"
        return 0
    fi

    install -d -o cowrie -g cowrie -m 0750 "$COWRIE_INSTALL_DIR"
    log "创建隔离的 Cowrie Python 虚拟环境"
    runuser -u cowrie -- python3 -m venv "$COWRIE_VENV"
    runuser -u cowrie -- env HOME="$COWRIE_INSTALL_DIR" \
        "$COWRIE_PYTHON" -m pip install --upgrade pip setuptools wheel
    runuser -u cowrie -- env HOME="$COWRIE_INSTALL_DIR" \
        "$COWRIE_PYTHON" -m pip install --upgrade "cowrie==${COWRIE_VERSION}"

    [[ -x "$COWRIE_BIN" ]] || die "Cowrie 命令未安装到虚拟环境"
    runuser -u cowrie -- "$COWRIE_PYTHON" -c 'import cowrie' || die "Cowrie Python 包导入失败"
}

initialise_cowrie_state() {
    if [[ "$INSTALL_WAS_MANAGED" -eq 1 ]]; then
        log "已有受管配置；将按本次环境变量协调受管键"
        return 0
    fi

    log "初始化 Cowrie 状态目录"
    (
        cd "$COWRIE_INSTALL_DIR"
        runuser -u cowrie -- env HOME="$COWRIE_INSTALL_DIR" "$COWRIE_BIN" init
    )
    [[ -f "$COWRIE_CONFIG" && ! -L "$COWRIE_CONFIG" ]] \
        || die "cowrie init 未生成普通配置文件：$COWRIE_CONFIG"
}

set_ini_value() {
    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"

    reject_symlink_components "$file"
    [[ -f "$file" ]] || die "配置文件不存在：$file"
    python3 - "$file" "$section" "$key" "$value" <<'PY'
from pathlib import Path
import os
import re
import stat
import sys
import tempfile

path = Path(sys.argv[1])
section = sys.argv[2]
key = sys.argv[3]
value = sys.argv[4]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
section_re = re.compile(r"^\s*\[([^]]+)]\s*$")
key_re = re.compile(rf"^\s*[#;]?\s*{re.escape(key)}\s*=")
out = []
in_target = False
found_section = False
written = False

for line in lines:
    match = section_re.match(line.strip())
    if match:
        if in_target and not written:
            if out and not out[-1].endswith("\n"):
                out[-1] += "\n"
            out.append(f"{key} = {value}\n")
            written = True
        in_target = match.group(1).strip() == section
        found_section = found_section or in_target

    if in_target and key_re.match(line):
        if not written:
            out.append(f"{key} = {value}\n")
            written = True
        continue
    out.append(line)

if in_target and not written:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(f"{key} = {value}\n")

if not found_section:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.extend([f"\n[{section}]\n", f"{key} = {value}\n"])

data = "".join(out)
metadata = path.stat()
descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
        os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
        if os.geteuid() == 0:
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

ensure_runtime_directory() {
    local path="$1"
    reject_symlink_components "$path"
    [[ ! -e "$path" || -d "$path" ]] || die "运行目录路径不是目录：$path"
    install -d -o cowrie -g cowrie -m 0750 "$path"
}

configure_cowrie() {
    reject_symlink_components "$COWRIE_CONFIG"
    set_ini_value "$COWRIE_CONFIG" honeypot hostname "$COWRIE_HOSTNAME"
    set_ini_value "$COWRIE_CONFIG" honeypot download_limit_size "$COWRIE_DOWNLOAD_LIMIT"
    set_ini_value "$COWRIE_CONFIG" ssh listen_endpoints "tcp:${COWRIE_SSH_PORT}:interface=0.0.0.0"

    ensure_runtime_directory "$COWRIE_INSTALL_DIR/var"
    ensure_runtime_directory "$COWRIE_INSTALL_DIR/var/log"
    ensure_runtime_directory "$COWRIE_INSTALL_DIR/var/log/cowrie"
    ensure_runtime_directory "$COWRIE_INSTALL_DIR/var/lib"
    ensure_runtime_directory "$COWRIE_INSTALL_DIR/var/lib/cowrie"
    ensure_runtime_directory "$COWRIE_INSTALL_DIR/var/run"
}

harden_cowrie_permissions() {
    reject_symlink_components "$COWRIE_INSTALL_DIR"
    reject_symlink_components "$COWRIE_VENV"
    reject_symlink_components "$COWRIE_CONFIG"
    reject_symlink_components "$COWRIE_INSTALL_DIR/var"

    # Static state is root-owned but group-readable by the service. The venv
    # contains no secrets, so it is root:root and explicitly readable/executable.
    chown -hR root:cowrie "$COWRIE_INSTALL_DIR"
    chmod -R go-w "$COWRIE_INSTALL_DIR"
    find "$COWRIE_INSTALL_DIR" \
        -path "$COWRIE_INSTALL_DIR/var" -prune -o \
        -path "$COWRIE_VENV" -prune -o \
        -type d -exec chmod g+rx {} + -o \
        -type f -exec chmod g+r {} +
    chown -hR root:root "$COWRIE_VENV"
    chmod -R a+rX,go-w "$COWRIE_VENV"
    chown -hR cowrie:cowrie "$COWRIE_INSTALL_DIR/var"
    chmod 0750 "$COWRIE_INSTALL_DIR" "$COWRIE_INSTALL_DIR/etc" "$COWRIE_INSTALL_DIR/var"
    chown root:cowrie "$COWRIE_INSTALL_DIR" "$COWRIE_INSTALL_DIR/etc" "$COWRIE_CONFIG"
    chmod 0640 "$COWRIE_CONFIG"

    atomic_install_from_stdin "$CYBERSENTRY_MARKER" 0644 root root <<EOF
managed-by=CyberSentry
EOF
    atomic_install_from_stdin "$METADATA" 0644 root root <<EOF
${COWRIE_VERSION}
EOF
}

get_effective_ssh_ports() {
    local output ports port

    command -v sshd >/dev/null 2>&1 || die "未找到 sshd，无法可靠配置 Fail2ban sshd jail"
    output="$(sshd -T 2>/dev/null)" || die "sshd -T 失败，拒绝猜测 SSH 端口"
    ports="$(printf '%s\n' "$output" | awk '$1 == "port" {print $2}' | sort -nu)"
    [[ -n "$ports" ]] || die "sshd -T 未返回有效端口"

    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || die "sshd 返回非数字端口：$port"
        port=$((10#$port))
        ((port >= 1 && port <= 65535)) || die "sshd 返回越界端口：$port"
    done <<< "$ports"

    printf '%s\n' "$ports" | paste -sd, -
}

wait_for_fail2ban_readiness() {
    local elapsed=0

    while ((elapsed < FAIL2BAN_READY_TIMEOUT)); do
        if fail2ban-client ping >/dev/null 2>&1 \
            && fail2ban-client status sshd >/dev/null 2>&1; then
            log "Fail2ban 服务与 sshd jail 已就绪"
            return 0
        fi

        if systemctl is-failed --quiet fail2ban; then
            break
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    warn "Fail2ban 未在 ${FAIL2BAN_READY_TIMEOUT} 秒内就绪，输出诊断信息"
    systemctl status fail2ban --no-pager >&2 || true
    journalctl -u fail2ban -n 50 --no-pager >&2 || true
    die "Fail2ban sshd jail 未能在 ${FAIL2BAN_READY_TIMEOUT} 秒内就绪"
}

configure_fail2ban() {
    local ssh_ports
    ssh_ports="$(get_effective_ssh_ports)"

    install -d -m 0755 /etc/fail2ban/jail.d
    atomic_install_from_stdin "$FAIL2BAN_CONFIG" 0644 root root <<EOF
[sshd]
enabled = true
backend = systemd
port = ${ssh_ports}
filter = sshd
bantime = 86400
findtime = 1800
maxretry = 3
EOF

    fail2ban-client -t || die "Fail2ban 配置测试失败"
    systemctl enable fail2ban >/dev/null
    systemctl restart fail2ban
    wait_for_fail2ban_readiness
    log "Fail2ban 已启用，保护 SSH 端口 ${ssh_ports}"
}

configure_cowrie_service() {
    atomic_install_from_stdin "$COWRIE_SERVICE" 0644 root root <<EOF
[Unit]
Description=Cowrie SSH/Telnet Honeypot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=cowrie
Group=cowrie
WorkingDirectory=${COWRIE_INSTALL_DIR}
Environment=HOME=${COWRIE_INSTALL_DIR}/var/lib/cowrie
Environment=COWRIE_STDOUT=yes
Environment=PATH=${COWRIE_VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${COWRIE_BIN} start
Restart=on-failure
RestartSec=10
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${COWRIE_INSTALL_DIR}/var
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

    atomic_install_from_stdin "$COWRIE_LOGROTATE" 0644 root root <<EOF
${COWRIE_INSTALL_DIR}/var/log/cowrie/*.log ${COWRIE_INSTALL_DIR}/var/log/cowrie/*.json {
    daily
    rotate ${LOG_RETENTION_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su cowrie cowrie
}
EOF
}

report_cowrie_diagnostics() {
    warn "Cowrie 启动检查失败，输出诊断信息"
    systemctl status cowrie --no-pager >&2 || true
    journalctl -u cowrie -n 80 --no-pager >&2 || true
}

start_and_verify_cowrie() {
    local elapsed

    systemctl daemon-reload
    systemctl enable cowrie >/dev/null
    systemctl restart cowrie

    elapsed=0
    while ((elapsed < COWRIE_SETTLE_SECONDS)); do
        sleep 1
        if ! systemctl is-active --quiet cowrie; then
            report_cowrie_diagnostics
            die "Cowrie 在稳定性观察期内退出"
        fi
        elapsed=$((elapsed + 1))
    done

    if ! ss -H -ltn | awk -v port="$COWRIE_SSH_PORT" '
        $4 ~ (":" port "$") { found = 1 }
        END { exit(found ? 0 : 1) }
    '; then
        report_cowrie_diagnostics
        die "Cowrie 服务 active，但未监听配置端口 ${COWRIE_SSH_PORT}"
    fi
    log "Cowrie 已稳定运行 ${COWRIE_SETTLE_SECONDS} 秒并监听 ${COWRIE_SSH_PORT}/tcp"
}

print_summary() {
    printf '\n安装完成\n'
    printf '  Cowrie 版本：%s\n' "$COWRIE_VERSION"
    printf '  Cowrie 端口：%s/tcp\n' "$COWRIE_SSH_PORT"
    printf '  Cowrie 目录：%s\n' "$COWRIE_INSTALL_DIR"
    printf '  Cowrie 日志：%s/var/log/cowrie/\n' "$COWRIE_INSTALL_DIR"
    printf '  Fail2ban：%s\n' "$(systemctl is-active fail2ban 2>/dev/null || true)"
    printf '  Cowrie：%s\n' "$(systemctl is-active cowrie 2>/dev/null || true)"
    [[ -n "$LEGACY_BACKUP" ]] && printf '  旧安装备份：%s\n' "$LEGACY_BACKUP"

    printf '\n本脚本没有修改 SSH 端口、认证方式或 UFW。\n'
    printf '如果使用 UFW，请确认已放行：ufw allow %s/tcp comment "Cowrie Honeypot"\n' "$COWRIE_SSH_PORT"
    printf 'Cowrie 当前监听高位端口；若要接收公网 22 端口流量，请先迁移真实 SSH，再单独配置 nftables/iptables 转发。\n'
    printf '\n查看状态：systemctl status cowrie fail2ban\n'
    printf '查看日志：journalctl -u cowrie -f\n'
}

main() {
    require_root
    check_platform
    validate_settings
    if is_managed_installation; then
        INSTALL_WAS_MANAGED=1
    fi
    begin_transaction
    install_dependencies
    ensure_cowrie_account
    systemctl stop cowrie >/dev/null 2>&1 || true
    preserve_unrecognised_installation
    create_cowrie_environment
    initialise_cowrie_state
    configure_cowrie
    harden_cowrie_permissions
    configure_fail2ban
    configure_cowrie_service
    start_and_verify_cowrie

    TRANSACTION_COMMITTED=1
    print_summary
}

main "$@"
