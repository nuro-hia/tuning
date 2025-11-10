#!/bin/bash
# =========================================================
# 🧠 Nuro / NAT 多实例宿主机系统优化配置
# 支持 Debian / Ubuntu / AlmaLinux / Rocky / CentOS
# 自动调高 inotify、文件句柄、TCP 参数、日志限制、zram
# =========================================================

set -e

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
  echo "❌ 不支持的系统，请使用 Debian/Ubuntu 或 AlmaLinux/CentOS/RHEL。"
  exit 1
fi

echo "✅ 检测到系统: $OS_FAMILY"

# 1️⃣ 内核 inotify & 文件句柄 调优
echo "🔧 应用 inotify / 文件句柄 参数..."
sysctl -w fs.inotify.max_user_instances=32768
sysctl -w fs.inotify.max_user_watches=4194304
sysctl -w fs.inotify.max_queued_events=262144
sysctl -w fs.file-max=2097152
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

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

sysctl --system >/dev/null

# 2️⃣ 调整 ulimit 限制
echo "🔧 设置文件打开数限制..."
grep -q 'nofile' /etc/security/limits.conf || cat >>/etc/security/limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat >/etc/systemd/system.conf.d/99-nuro.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
cp /etc/systemd/system.conf.d/99-nuro.conf /etc/systemd/user.conf.d/99-nuro.conf 2>/dev/null || true

# 3️⃣ zram 安装与启用
echo "🧊 检查并启用 zram 压缩内存..."
if [ "$OS_FAMILY" = "debian" ]; then
  $UPDATE_CMD >/dev/null 2>&1
  $PKG_INSTALL zram-tools >/dev/null 2>&1
  cat >/etc/default/zram-config <<'EOF'
PERCENT=50
ALGO=zstd
EOF
  systemctl enable --now zram-config.service
else
  $UPDATE_CMD >/dev/null 2>&1
  $PKG_INSTALL zram-generator >/dev/null 2>&1
  mkdir -p /etc/systemd/zram-generator.conf.d
  cat >/etc/systemd/zram-generator.conf.d/override.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
  systemctl daemon-reload
  systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
fi

# 4️⃣ journald 日志限制（防止爆盘）
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

echo "✅ 所有优化已完成，建议重启系统以确保完全生效。"
