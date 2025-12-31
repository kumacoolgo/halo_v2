#!/usr/bin/env bash
set -euo pipefail

# ================= 元信息 =================
SCRIPT_NAME="halo-vps-deploy"
SCRIPT_VERSION="1.2.0"
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
NO_COLOR=false

# ================= 颜色控制 =================
if [[ -t 1 ]]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  CYAN="\033[36m"
  RESET="\033[0m"
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

# ================= 工具函数 =================
die() {
  echo -e "${RED}❌ $1${RESET}" >&2
  exit 1
}

info() {
  echo -e "${CYAN}▶ $1${RESET}"
}

warn() {
  echo -e "${YELLOW}⚠️ $1${RESET}"
}

# ================= 环境检测 =================
check_env() {
  [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"

  [[ -f /etc/os-release ]] || die "无法识别操作系统"
  . /etc/os-release

  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    warn "当前系统是 $ID，脚本仅在 Ubuntu/Debian 上完整测试"
  fi

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64|aarch64|arm64) ;;
    *)
      die "不支持的架构: $ARCH（仅支持 amd64 / arm64）"
      ;;
  esac
}

# ================= 端口占用检测 =================
check_ports() {
  if command -v lsof >/dev/null; then
    if lsof -i :80 -sTCP:LISTEN -t >/dev/null || lsof -i :443 -sTCP:LISTEN -t >/dev/null; then
      warn "检测到端口 80 或 443 被占用 (可能是宿主机的 Nginx/Apache)"
      warn "这可能导致 Docker 容器无法启动。建议卸载宿主机的 Web 服务。"
      read -r -p "是否继续？[y/N] " response
      [[ "$response" =~ ^[yY]$ ]] || die "已取消操作"
    fi
  fi
}

# ================= Docker Compose 检测 =================
get_docker_compose_cmd() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null; then
    echo "docker-compose"
  else
    echo ""
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
    --no-color) NO_COLOR=true; shift ;;
    -h|--help)
      echo "$SCRIPT_NAME v$SCRIPT_VERSION"
      echo ""
      echo "Usage:"
      echo "  --domain     <required>  域名，如 blog.aa.com"
      echo "  --ws-path    <optional>  WS 路径，默认 /connect"
      echo "  --name       <optional>  节点名称"
      echo "  --dry-run                只输出配置，不修改系统"
      echo "  --uninstall              干净卸载本项目"
      exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

check_env

# ================= 卸载逻辑 =================
if $UNINSTALL; then
  info "开始卸载 $SCRIPT_NAME"

  if [[ -d "$BASE_DIR" ]]; then
    cd "$BASE_DIR"
    DC_CMD=$(get_docker_compose_cmd)

    if [[ -n "$DC_CMD" ]]; then
      info "使用 $DC_CMD 停止并移除容器"
      $DC_CMD down || warn "容器停止失败，请手动检查"
    else
      warn "未检测到 docker compose，跳过容器停止"
    fi

    cd /
    info "删除目录 $BASE_DIR"
    rm -rf "$BASE_DIR"
  else
    warn "未发现 $BASE_DIR，可能已卸载"
  fi

  echo ""
  echo -e "${GREEN}✅ 卸载完成${RESET}"
  warn "Docker 本身、UFW 规则未做修改（这是设计行为）"
  exit 0
fi

# ================= 参数校验 =================
[[ -n "$DOMAIN" ]] || die "--domain 是必填参数"
[[ "$WS_PATH" =~ ^/ ]] || die "--ws-path 必须以 / 开头"

# ================= UUID 逻辑 (复用或新建) =================
UUID=""
CONFIG_FILE="$BASE_DIR/v2ray/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
  # 尝试从现有配置中提取 UUID，避免重新部署时导致客户端断连
  EXISTING_UUID=$(grep -oP '"id": "\K[0-9a-f-]{36}' "$CONFIG_FILE" || true)
  if [[ -n "$EXISTING_UUID" ]]; then
    UUID="$EXISTING_UUID"
    info "检测到现有配置，复用 UUID: $UUID"
  fi
fi

if [[ -z "$UUID" ]]; then
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  info "生成新 UUID: $UUID"
fi

# ================= 部署计划 =================
echo ""
echo "========== 部署计划 =========="
echo "Script   : $SCRIPT_NAME v$SCRIPT_VERSION"
echo "Domain   : $DOMAIN"
echo "WS Path  : $WS_PATH"
echo "Name     : $NAME"
echo "UUID     : $UUID"
echo "Base Dir : $BASE_DIR"
echo "Arch     : $(uname -m)"
echo "Mode     : $( $DRY_RUN && echo DRY-RUN || echo APPLY )"
echo "=============================="
echo ""

# ================= DRY-RUN =================
if $DRY_RUN; then
  echo "🔐 VLESS 链接预览："
  echo "vless://$UUID@$DOMAIN:443?encryption=none&type=ws&path=$(printf %s "$WS_PATH" | sed 's/\//%2F/g')&security=tls&sni=$DOMAIN#$NAME"
  exit 0
fi

# ================= 实际部署 =================
check_ports

info "更新系统并安装基础依赖"
apt-get update -y >/dev/null 2>&1 || warn "apt update 出现警告，继续执行"
apt-get install -y curl ca-certificates ufw grep lsof >/dev/null

if ! command -v docker >/dev/null; then
  info "安装 Docker"
  curl -fsSL https://get.docker.com | bash
  systemctl enable --now docker
else
  info "Docker 已存在，跳过安装"
fi

DC_CMD=$(get_docker_compose_cmd)
if [[ -z "$DC_CMD" ]]; then
  info "安装 docker compose 插件"
  apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
  DC_CMD=$(get_docker_compose_cmd)
fi

[[ -n "$DC_CMD" ]] || die "Docker Compose 不可用"

info "使用 Docker Compose: $DC_CMD"

info "创建目录结构"
mkdir -p "$BASE_DIR"/{npm/data,npm/letsencrypt,halo,v2ray}
cd "$BASE_DIR"

info "写入 VLESS 配置"
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

info "写入 docker-compose.yml"
# 优化点：添加 HALO_EXTERNAL_URL 和时区映射
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
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:81"]
      interval: 30s
      timeout: 10s
      retries: 3

  halo:
    image: halohub/halo:2.20
    container_name: halo
    volumes:
      - ./halo:/root/.halo2
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    environment:
      - HALO_EXTERNAL_URL=https://$DOMAIN
      # 如果内存有限，可限制 JVM 内存，例如：
      # - JVM_OPTS=-Xmx256m -Xms256m
    restart: always

  v2ray:
    image: v2fly/v2fly-core:latest
    container_name: v2ray
    volumes:
      - ./v2ray:/etc/v2ray
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    command: run -c /etc/v2ray/config.json
    restart: always
EOF

info "配置防火墙（安全模式）"
# 自动检测 SSH 端口
SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
SSH_PORT=${SSH_PORT:-22}

# 判断 SSH 端口是否有效（防止异常配置）
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    warn "未能自动识别 SSH 端口，默认放行 22"
    SSH_PORT=22
fi

info "放行 SSH 端口: $SSH_PORT"
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 81/tcp

if ! ufw status | grep -q "Status: active"; then
  echo "y" | ufw enable
fi

info "启动服务"
$DC_CMD up -d

# ================= 输出 =================
VLESS_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=ws&path=$(printf %s "$WS_PATH" | sed 's/\//%2F/g')&security=tls&sni=$DOMAIN#$NAME"

echo ""
echo "========== 部署完成 =========="
echo ""
echo "🔹 NPM 管理面板: http://$DOMAIN:81"
echo "   默认账号: admin@example.com"
echo "   默认密码: changeme"
echo ""
echo "⚠️  请登录 NPM 面板完成以下 2 步配置："
echo ""
echo "1️⃣  配置 Halo 博客:"
echo "   - 点击 Proxy Hosts -> Add Proxy Host"
echo "   - Domain Names: $DOMAIN"
echo "   - Scheme: http | Forward Hostname: halo | Forward Port: 8090"
echo "   - SSL 选项卡: 勾选 Force SSL, 申请 Let's Encrypt 证书"
echo ""
echo "2️⃣  配置 VLESS 节点 (在同一个配置中):"
echo "   - 编辑刚才创建的 $DOMAIN 配置"
echo "   - 点击 Custom Locations 选项卡 -> Add Location"
echo "   - Define Location (Path): $WS_PATH"
echo "   - Scheme: http | Forward Hostname: v2ray | Forward Port: 10000"
echo "   - ⚙️ 点击齿轮图标 (Advanced): 输入以下两行代码以支持 WebSocket:"
echo "       proxy_set_header Upgrade \$http_upgrade;"
echo "       proxy_set_header Connection \"upgrade\";"
echo ""
echo "📋 VLESS 链接（已保存至 $BASE_DIR/vless.txt）："
echo -e "${GREEN}$VLESS_LINK${RESET}"
echo "$VLESS_LINK" > "$BASE_DIR/vless.txt"
echo ""
