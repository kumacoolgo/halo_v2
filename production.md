# 生产环境部署说明（production.md）

本文件用于 **从 0 到可用** 在一台全新 VPS 上部署：
- Halo 博客（伪装）
- Nginx Proxy Manager
- VLESS / V2Ray（WebSocket + TLS）

示例域名统一使用：**admin.domain.com**  
请在实际部署时替换为你自己的域名。

---

## 1️⃣ 域名解析到 VPS

在你的域名服务商（如阿里云 DNS）中添加：

| 类型 | 主机记录 | 记录值 |
|----|----|----|
| A | admin | VPS 公网 IPv4 |
| A | blog | VPS 公网 IPv4（可选） |

说明：
- 确保 DNS 服务器指向 **阿里云 DNS**
- 等待 1–10 分钟解析生效

验证：
```bash
ping admin.domain.com
```

---

## 2️⃣ VPS 初始化 & 一键部署

登录 VPS：
```bash
ssh root@VPS_IP
```

创建工作目录：
```bash
mkdir -p /opt/deploy && cd /opt/deploy
```

一键部署（示例）：
```bash
curl -fsSL https://example.com/halo-vps-deploy.sh | bash -s --   --domain admin.domain.com   --ws-path /connect   --name halo-cn
```

部署完成后会输出：
- NPM 管理地址
- VLESS 链接
- 配置路径 `/opt/halo-stack`

---

## 3️⃣ Nginx Proxy Manager 设置

### 登录 NPM
```
http://admin.domain.com:81
```
默认账号：
- 用户：admin@example.com
- 密码：changeme

首次登录请修改密码和邮箱（邮箱用于证书）。

---

### 3.1 配置 Halo 博客

Proxy Hosts → Add Proxy Host

**Details**
- Domain Names：`admin.domain.com`
- Scheme：`http`
- Forward Hostname：`halo`
- Forward Port：`8090`
- WebSocket Support：✅

**SSL**
- Request a new SSL Certificate
- Force SSL：✅

保存。

---

### 3.2 配置 VLESS（同一个域名）

编辑刚才的 `admin.domain.com`：

Custom Locations → Add Location

- Location：`/connect`
- Scheme：`http`
- Forward Hostname：`v2ray`
- Forward Port：`10000`

⚙ Advanced 中填写：
```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

保存。

---

## 4️⃣ Halo 博客初始化

访问：
```
https://admin.domain.com
```

按照向导完成：
- 管理员账号
- 博客标题
- 站点地址（保持 https）

Halo 仅作为正常博客使用，无需特殊配置。

---

## 5️⃣ VPN / VLESS 链接查看

部署脚本已生成：
```bash
cat /opt/halo-stack/vless.txt
```

示例格式：
```
vless://UUID@admin.domain.com:443?encryption=none&type=ws&path=%2Fconnect&security=tls&sni=admin.domain.com#halo-cn
```

### Android 推荐客户端
- v2rayNG
- Clash Meta for Android

### Windows / macOS
- Clash Meta
- v2rayN

---

## 6️⃣ 自检清单（上线必查）

- [ ] `ping admin.domain.com` 正常
- [ ] https://admin.domain.com 可访问
- [ ] NPM 中证书状态为 Valid
- [ ] `/connect` 返回 400（正常）
- [ ] 客户端可成功连接
- [ ] Halo 后台可登录

---

## 7️⃣ 维护建议（稳 3 年）

- 不频繁重装 VPS
- 不修改 WS 路径
- 3–6 个月更新一次 Docker 镜像
- 保留 `/opt/halo-stack` 目录备份

---

**状态：Level 2 稳定方案（不对抗，不折腾）**
