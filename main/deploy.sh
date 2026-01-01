#!/usr/bin/env bash
set -euo pipefail

# ================= 元信息 =================
SCRIPT_NAME="halo-vps-deploy"
SCRIPT_VERSION="1.3.0"
BASE_DIR="/opt/halo-stack"

# ================= 默认值 =================
DEFAULT_WS_PATH="/connect"
DEFAULT_NAME="halo-cn"

# ================= 状态 =================
DOMAIN=""
WS_PATH="$DEFAULT_WS_PATH"
NAME="$DEFAULT_NAME"
DRY_RUN=false
UNINSTALL=false

# ================= 工具函数 =================
die() { echo -e "\033[31m❌ $1\033[0m"; exit 1; }
info() { echo -e "\033[36m▶ $1\033[0m"; }
warn() { echo -e "\033[33m⚠️ $1\033[0m"; }

# ================= 环境检测 =================
check_env() {
  [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"
  [[ -f /etc/os-release ]] || die "无法识别操作系统"
  . /etc/os-release
  ARCH="$(uname -m)"
  case "$ARCH" in x86_64|amd64|aarch64|arm64) ;; *) die "不支持的架构";; esac
}

get_docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null; then
    echo "docker-compose"
  else
    die "Docker Compose 不可用"
  fi
}

# ================= 参数解析 =================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --ws-path) WS_PATH="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) die "未知参数 $1" ;;
  esac
done

check_env

[[ -n "$DOMAIN" ]] || die "--domain 必填"
[[ "$WS_PATH" =~ ^/ ]] || die "--ws-path 必须以 / 开头"

UUID="$(cat /proc/sys/kernel/random/uuid)"

# ================= 卸载 =================
if $UNINSTALL; then
  cd "$BASE_DIR" || exit 0
  $(get_docker_compose_cmd) down || true
  rm -rf "$BASE_DIR"
  echo "✅ 已卸载"
  exit 0
fi

# ================= 依赖 =================
info "安装系统依赖"
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y curl ca-certificates ufw >/dev/null

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | bash
  systemctl enable --now docker
fi

DC_CMD=$(get_docker_compose_cmd)

# ================= 目录 =================
info "创建目录结构"
mkdir -p "$BASE_DIR"/{npm/data,npm/letsencrypt,halo,v2ray,lunatv,kvrocks}
cd "$BASE_DIR"

# ================= V2Ray =================
info "写入 V2Ray 配置"
cat > v2ray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 10000,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "$WS_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ================= Docker Compose =================
info "写入 docker-compose.yml"
cat > docker-compose.yml <<EOF
version: "3.8"

services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    ports: ["80:80","81:81","443:443"]
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    restart: always

  halo:
    image: halohub/halo:2.22.4
    container_name: halo
    volumes:
      - ./halo:/root/.halo2
    environment:
      - HALO_EXTERNAL_URL=https://$DOMAIN
    restart: always

  v2ray:
    image: v2fly/v2fly-core:latest
    container_name: v2ray
    volumes:
      - ./v2ray:/etc/v2ray
    command: run -c /etc/v2ray/config.json
    restart: always

  lunatv:
    image: ghcr.io/szemeng76/lunatv:latest
    container_name: lunatv
    restart: always
    environment:
      - USERNAME=admin
      - PASSWORD=Ok65321
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://kvrocks:6666
      - SITE_BASE=https://$DOMAIN/tv
      - NEXT_PUBLIC_SITE_NAME=LunaTV
    depends_on:
      - kvrocks

  kvrocks:
    image: apache/kvrocks
    container_name: kvrocks
    restart: unless-stopped
    volumes:
      - ./kvrocks:/var/lib/kvrocks
EOF

# ================= 防火墙 =================
info "配置防火墙"
ufw allow 22/tcp || true
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 81/tcp
ufw --force enable

# ================= 启动 =================
info "启动所有服务"
$DC_CMD up -d

# ================= 输出 =================
VLESS="vless://$UUID@$DOMAIN:443?encryption=none&type=ws&path=$(printf %s "$WS_PATH" | sed 's/\//%2F/g')&security=tls&sni=$DOMAIN#$NAME"
echo "$VLESS" > "$BASE_DIR/vless.txt"

echo ""
echo "================= 完成 ================="
echo "NPM 面板: http://$DOMAIN:81"
echo "VLESS: $VLESS"
echo ""
echo "⚠️  接下来只需在 NPM 中手动配置："
echo ""
echo "1️⃣ Proxy Host: $DOMAIN -> halo:8090"
echo "2️⃣ Location: $WS_PATH -> v2ray:10000 (加 WS header)"
echo "3️⃣ Location: /tv -> lunatv:3000 (rewrite /tv)"
echo ""
