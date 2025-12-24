#!/bin/bash
# =========================================================
# 🧠 Nuro / NAT 多实例宿主机系统优化配置（增强版）
# 支持 Debian / Ubuntu / AlmaLinux / Rocky / CentOS
# 自动调高 inotify、文件句柄、TCP 参数、日志限制、zram
# =========================================================

set -euo pipefail

log()  { echo -e "✅ $*"; }
warn() { echo -e "⚠️ $*"; }
err()  { echo -e "❌ $*" >&2; }

echo "🔧 正在检测系统类型..."
if [ -f /etc/debian_version ]; then
  OS_FAMILY="debian"
  PKG_INSTALL="apt-get install -y"
  UPDATE_CMD="apt-get update -y"
elif [ -f /etc/redhat-release ]; then
  OS_FAMILY="rhel"
  if command -v dnf >/dev/null 2>&1; then
    PKG_INSTALL="dnf install -y"
    UPDATE_CMD="dnf update -y"
  else
    PKG_INSTALL="yum install -y"
    UPDATE_CMD="yum update -y"
  fi
else
  err "不支持的系统，请使用 Debian/Ubuntu 或 AlmaLinux/CentOS/RHEL。"
  exit 1
fi

log "检测到系统: $OS_FAMILY"

# ---------------------------------------------------------
# 1️⃣ sysctl：inotify / 文件句柄 / TCP 参数调优
# ---------------------------------------------------------
echo "🔧 应用 inotify / 文件句柄 / TCP 参数..."
sysctl -w fs.inotify.max_user_instances=32768 || true
sysctl -w fs.inotify.max_user_watches=4194304 || true
sysctl -w fs.inotify.max_queued_events=262144 || true
sysctl -w fs.file-max=2097152 || true
sysctl -w net.core.somaxconn=65535 || true
sysctl -w net.ipv4.ip_local_port_range="1024 65535" || true

cat >/etc/sysctl.d/99-nuro-tuning.conf <<'EOF'
# ===================== Inotify 调优 =====================
fs.inotify.max_user_instances = 32768
fs.inotify.max_user_watches   = 4194304
fs.inotify.max_queued_events  = 262144

# ===================== 文件句柄 / TCP 队列 =====================
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535

# ===================== TCP 优化 =====================
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
EOF

sysctl --system >/dev/null 2>&1 || warn "sysctl --system 执行失败（不影响已设置参数）"

# ---------------------------------------------------------
# 2️⃣ ulimit：nofile/nproc 调整并持久化
# ---------------------------------------------------------
echo "🔧 设置文件打开数限制..."
if ! grep -q "1048576" /etc/security/limits.conf 2>/dev/null; then
  cat >>/etc/security/limits.conf <<'EOF'

# ===== Nuro tuning =====
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  1048576
* hard nproc  1048576
EOF
fi

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat >/etc/systemd/system.conf.d/99-nuro.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
cp /etc/systemd/system.conf.d/99-nuro.conf /etc/systemd/user.conf.d/99-nuro.conf 2>/dev/null || true

systemctl daemon-reexec >/dev/null 2>&1 || true

# ---------------------------------------------------------
# 3️⃣ zram：Debian/Ubuntu 用 zram-tools；RHEL 用 zram-generator
# ---------------------------------------------------------
echo "🧊 检查并启用 zram 压缩内存..."

if [ "$OS_FAMILY" = "debian" ]; then
  # apt 更新可能因为坏源失败，这里不让脚本死
  if ! $UPDATE_CMD >/dev/null 2>&1; then
    warn "apt-get update 失败（可能有旧/坏源），继续尝试安装 zram-tools..."
    warn "建议检查 sources.list（如 openvz/virtualizor/wheezy）"
  fi

  if ! $PKG_INSTALL zram-tools >/dev/null 2>&1; then
    err "zram-tools 安装失败，请手动检查 apt 源"
    exit 1
  fi

  # zram-tools 的配置文件（如果存在这个文件）
  cat >/etc/default/zramswap <<'EOF'
# ===== Nuro zram config =====
PERCENT=50
ALGO=zstd
PRIORITY=100
EOF

  # 兼容不同 service 名称
  if systemctl list-unit-files 2>/dev/null | grep -q '^zramswap.service'; then
    systemctl enable --now zramswap.service
    log "已启用 zramswap.service"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^zram-config.service'; then
    systemctl enable --now zram-config.service
    log "已启用 zram-config.service"
  else
    warn "未找到 zram service（可能不是 systemd 环境），跳过启用"
  fi

else
  # RHEL 分支
  if ! $UPDATE_CMD >/dev/null 2>&1; then
    warn "系统更新失败，继续尝试安装 zram-generator..."
  fi

  if ! $PKG_INSTALL zram-generator >/dev/null 2>&1; then
    err "zram-generator 安装失败"
    exit 1
  fi

  mkdir -p /etc/systemd/zram-generator.conf.d
  cat >/etc/systemd/zram-generator.conf.d/override.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

  systemctl daemon-reload
  systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
  log "已配置 zram-generator"
fi

# ---------------------------------------------------------
# 4️⃣ journald：限制日志体积（防止爆盘）
# ---------------------------------------------------------
echo "🧾 限制 systemd 日志体积..."
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-nuro-loglimit.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
RuntimeMaxUse=100M
MaxFileSec=1week
EOF
systemctl restart systemd-journald 2>/dev/null || true

# ---------------------------------------------------------
# 5️⃣ 输出最终状态
# ---------------------------------------------------------
echo
log "所有优化已完成。"
echo "------ 当前关键参数检查 ------"
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches fs.file-max net.core.somaxconn net.ipv4.ip_local_port_range 2>/dev/null || true
echo "------ ulimit（新会话生效） ------"
ulimit -n || true
echo "------ zram 状态（如果支持） ------"
lsblk 2>/dev/null | grep -i zram || true
swapon --show 2>/dev/null || true
echo "--------------------------------"
echo "✅ 建议重启后确认 systemd 默认限制与 zram swap 持久生效。"
