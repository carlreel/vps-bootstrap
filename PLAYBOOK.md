# VPS 自建代理 · 部署 Playbook

> **给 AI 读的文档**，不是给小白看的教程。
> 目标：拿到一台新 VPS + 一个新网络环境，能在 30 分钟内判断出「该走哪条路」，并避开已知的 8 个坑。
>
> 本文档基于 2026-11-20 的一次真实部署（CloudCone 洛杉矶 / Ubuntu 24.04 / 中国移动家宽）总结。
> 配套脚本：`vps-probe.sh`（只读状态探针）。

---

## 0. 第一步永远是「判断环境」，不是「装软件」

**90% 的失败源于选错路线，而不是命令敲错。**

装 sing-box 之前，必须先回答三个问题：

| 问题 | 怎么测 | 意义 |
|---|---|---|
| 1. 主机活着吗 | `ping <IP>` | ICMP 都不通 = 主机没起来 / IP 错了，别往下走 |
| 2. TCP 通吗 | 境外节点测 `IP:22`（check-host）；本地测 `IP:22` | 本地不通 + 境外通 = **你这条线路封了** |
| 3. UDP 通吗 | 装 Tailscale 看能否 `direct` 直连；或用 UDP 探针 | **决定你能不能自救** |

用 `check-host.net` 从境外测端口：

```
https://check-host.net/check-tcp?host=<IP>:<PORT>&max_nodes=5
```

如果境外全 OPEN、本地全 TIMEOUT —— **封锁在你这一侧，服务器无辜，别浪费时间查服务器。**

---

## 1. 决策树

```
买完 VPS，拿到 IP / root 密码
│
├─ A. ping 不通？
│   └─ 等 3-5 分钟（cloud-init 还在跑）→ 仍不通看面板状态
│
├─ B. ping 通，SSH 连不上
│   │
│   ├─ B1. 境外节点测 <IP>:22
│   │   ├─ 境外也不通 → sshd 没起 / 云防火墙 → 用面板 VNC 进去
│   │   └─ 境外通     → 你这条线路封了 → 继续 B2
│   │
│   └─ B2. 测 UDP 是否存活
│       ├─ UDP 通 → 【路线 ②】IP 级 TCP 封锁（本次情况）
│       └─ UDP 也不通 → 【路线 ③】全阻断，必须中继
│
└─ C. 能 SSH → 【路线 ①】直接按标准流程装
```

---

## 2. 三条路线

### ① IP 干净，直连可用
- 直接 `ssh root@IP`，端口 22
- 协议随便选（vless-reality 最快最稳）
- 不需要 Tailscale

### ② IP 级 TCP 全封，UDP 放行（**本次情况**）
**症状**：ICMP 通（延迟偏高 400ms+）；该 IP 的**所有 TCP 端口** SYN 无响应（22/443/8443/8080 全 TIMEOUT）；UDP 正常。

**判断依据**：TCP 换端口无效 → 不是端口封锁，是 IP 级丢弃。

**对策**：
1. **保命通道**：装 Tailscale（走 UDP 41641 打洞，能穿透）
2. **协议选型**：只选 **UDP 协议** —— hysteria2、TUIC
3. **端口跳跃**：给 hysteria2 加 UDP 端口范围 DNAT（对抗 UDP QoS）
4. **补一条 TCP 出路**：Cloudflare Tunnel（走 443 到 CF，CF 的 IP 国内可达）
5. **放弃**：vless-reality、vmess-ws 直连、anytls —— 全是 TCP，无解

### ③ 全阻断（TCP + UDP 都不通）
- 只能走中继：Cloudflare Tunnel、或一台没被封的中转机
- 或换机房 / 换 IP

---

## 3. 标准流程（按顺序，每步验证）

### 3.1 首次登录
```bash
# 面板 VNC 或直接 ssh
cat /etc/os-release          # 确认发行版，决定后续服务名（ssh vs sshd）
ip -br addr                  # 确认网卡和 IP
```

### 3.2 保命通道（**优先于一切**）
路线 ② 的情况下，这一步决定你后面会不会锁死自己。

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey=tskey-auth-xxxxx --hostname=<name> --accept-dns=false
tailscale set --ssh=false          # 关掉 Tailscale SSH，用标准 sshd + 密钥
```

**然后立刻验证**：从客户端 `ssh root@100.x.y.z` 能进，再继续下一步。

### 3.3 装 sing-box
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
```
装完后**立刻做 3.2 的密钥登录验证**，别急着改配置。

### 3.4 证书（acme.sh）
```bash
/root/.acme.sh/acme.sh --issue -d <域名> --standalone --keylength ec-256 --server letsencrypt
```

**关键判断**：`--standalone`（HTTP-01）**不需要 80 端口能从中国访问**，只需要能从 **Let's Encrypt 的验证节点（美国/欧洲）** 访问。中国线路封锁是出站方向，不影响 LE 入站验证。

### 3.5 端口跳跃（对抗 UDP QoS）
```bash
# 选一个不含已占用端口的 UDP 段，先查冲突
ss -lntup | awk '{print $5}' | grep -oE ':[0-9]+$' | tr -d ':' | sort -n | uniq

iptables  -t nat -A PREROUTING -i eth0 -p udp --dport 30000:35000 -j DNAT --to-destination :22047
ip6tables -t nat -A PREROUTING -i eth0 -p udp --dport 30000:35000 -j DNAT --to-destination :22047
```
节点链接加 `mport=30000-35000`，Clash 配置加 `ports: "30000-35000"`。

### 3.6 安全加固（顺序不能错）
```
密钥登录验证成功 → 才禁用密码
```

```bash
# Ubuntu 24.04 专属：改 sshd_config.d，不是 sshd_config
ls /etc/ssh/sshd_config.d/          # 先看有没有覆盖文件
cat > /etc/ssh/sshd_config.d/50-cloud-init.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
sshd -t && systemctl restart ssh
sshd -T | grep -iE 'passwordauthentication|permitrootlogin'   # 看最终生效值，不看文件
```

**iptables 三条铁律**：
1. **必须放行 `-i tailscale0`**，否则 Tailscale 被自己的防火墙切断
2. **放行全部业务端口**（TCP 和 UDP 分别列）
3. **不要 `iptables -t nat -F`**，会毁掉端口跳跃 DNAT

```bash
iptables -A INPUT -i tailscale0 -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# ... 业务端口 ...
iptables -A INPUT -j DROP
netfilter-persistent save
```

### 3.7 订阅服务（不要用 busybox httpd）
默认的 busybox httpd 是明文 HTTP、无密码、随机端口，扫到就能拿全部节点。

```bash
apt install -y nginx apache2-utils
htpasswd -cb /etc/nginx/auth/.htpasswd <user> <pass>
chmod 711 /root && chmod -R 755 /root/websbox     # nginx worker 要能遍历
# nginx: 80→301 → 443 SSL + auth_basic → root /root/websbox
```

**路线 ② 的关键补充**：公网 443 也被封，所以额外加一个**只绑 Tailscale IP** 的入口：

```nginx
server {
    listen 100.x.y.z:8080;      # 只监听 Tailscale 网段
    auth_basic "Subscription";
    auth_basic_user_file /etc/nginx/auth/.htpasswd;
    root /root/websbox;
}
```

这样国内客户端在**还没连上代理时**也能拉到订阅（前提：Tailscale 已连通）。

### 3.8 Cloudflare Tunnel（路线 ② 的 TCP 出路）
```bash
cloudflared service install <TOKEN>
```

**隧道本身健康 ≠ 能用**，必须核对三件事：

| 检查项 | 正确值 | 错误症状 |
|---|---|---|
| ingress 的 origin 协议 | `http://localhost:2082` | 写成 `https://` → 日志报 `tls: first record does not look like a TLS handshake` |
| 节点 SNI | 真实域名（如 `argo.example.com`） | 用 server 域名当 SNI → 403 |
| 节点 server | `cloudflare-ech.com`（或 CF 优选 IP） | 用真实域名 → 解析到的 IP 可能不通 |

**验证方法**（必须用完整 WS 头 + `--http1.1`）：
```bash
curl -s -o /dev/null -w "%{http_code}\n" --http1.1 \
  --resolve <域名>:443:<CF_IP> -H "Host: <域名>" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "https://<域名>/<ws-path>"
# 期望 HTTP 101
```

---

## 4. 踩坑清单（本次真实踩到的）

| # | 坑 | 症状 | 判据 / 解法 |
|---|---|---|---|
| 1 | **误判为端口封锁** | 换 443/8443/2222 都不通 | 一次测 5 个端口全 TIMEOUT → 是 IP 级封锁，不是端口 |
| 2 | **Ubuntu 24.04 的 `sshd_config.d` 覆盖** | 改 `sshd_config` 里的 PasswordAuthentication 无效 | 必须改 `sshd_config.d/*.conf`，用 `sshd -T` 看最终值 |
| 3 | **`ssh.socket` 激活让 Port 失效** | 改了 sshd_config 的 Port，新端口不监听 | `systemctl is-active ssh.socket`；改 `/etc/systemd/system/ssh.socket.d/*.conf` 的 `ListenStream` |
| 4 | **改完 iptables 把自己锁死** | SSH 断开且无法重连 | 必须 `-i tailscale0 -j ACCEPT`；`-m conntrack ESTABLISHED` 保留当前连接 |
| 5 | **warp-go 接管出站导致全断** | 装完 warp 后 SSH 断、出站全废、能 ping 不能 SSH | `ip rule` 里 WARP 的规则优先级高于 Tailscale 的表 52；`WARP` 接口 RX=0 TX 持续增长 = 隧道单向死 |
| 6 | **acme-yg 的 `ca.log` 与 sb 脚本不同步** | acme-yg 说有证书，sb 说没有 | sb 只认 `/root/ygkkkca/ca.log` 是否存在；补上这个文件即可 |
| 7 | **sed 替换含 `&` 的字符串** | 行被写成一坨乱码 | `&` 在 sed 替换串里代表整个匹配；改用 Python 按行重写 |
| 8 | **Cloudflare Tunnel ingress 协议错** | 隧道 HEALTHY，但访问 502/403 | origin 写成 `https://localhost:2082`，而 2082 是明文；改成 `http://` |

### 附加：协议可用性速查（路线 ②）

| 协议 | 传输层 | 国内可用 | 备注 |
|---|---|---|---|
| hysteria2 | UDP/QUIC | ✅ | 最快，配合端口跳跃 |
| TUIC v5 | UDP/QUIC | ✅ | 同 hysteria2 |
| vless-reality | TCP | ❌ | 不能套 CDN |
| vmess-ws（直连） | TCP | ❌ | 但可套 CDN |
| vmess-ws（Cloudflare） | TCP 443→CF | ⚠️ 需 ingress 配对 | 最稳的 TCP 出路 |
| anytls | TCP | ❌ | 无 UDP 变体，不能套 CDN，**无解** |

---

## 5. 状态探针

任何时候怀疑配置有问题，先在服务器跑：

```bash
bash vps-probe.sh              # 人类可读，带 ✓/✗ 标记和异常汇总
bash vps-probe.sh --json       # 机器可读，直接贴给 AI
```

输出覆盖：服务状态 / 端口监听 / 防火墙规则 / 证书有效期 / 隧道回源配置 / 订阅完整性 / **异常汇总**。

**给 AI 的用法**：把 `--json` 的输出原样贴过来，AI 不需要再问一轮"你装了什么、端口多少、防火墙怎么配的"。

---

## 6. 回滚

每次改动前都留备份，命名 `<file>.bak-<YYYYmmdd-HHMMSS>`：

| 改动 | 备份位置 | 回滚 |
|---|---|---|
| sshd 配置 | `/root/backup-*/50-cloud-init.conf` | `cp` 回去 + `systemctl restart ssh` |
| iptables | `/root/backup-*/iptables.v4.before` | `iptables-restore < ...` |
| Clash 订阅 | `/root/clmi.yaml.bak-*` | `cp` 回去 |
| nginx 站点 | `/etc/nginx/sites-available/sub.bak-*` | `cp` 回去 + `nginx -t && systemctl reload nginx` |

**保命原则**：动网络配置前，先确认至少两条通道可用（如 Tailscale IP + 公网 22 经代理）。

---

## 7. 环境清单模板（部署完成后应达到的状态）

对照自己的机器填写，用来判断「是不是少了一步」：

```
机房/系统     : <机房> / Ubuntu 24.04 / 1C1G / 55G
IPv4          : <公网 IP>            ← 若 TCP 全封，标记「仅 UDP 可用」
IPv6          : <公网 IPv6>          ← 可选，有则优先用于 SSR / 直连测试

服务          : sing-box / nginx / cloudflared / tailscaled / fail2ban
协议端口      : vless:30424  vmess-ws:2082  hysteria2:22047(跳跃 30000-35000)
                tuic:27567   anytls:51548
隧道          : cloudflared token 模式，ingress <argo.example.com> → http://localhost:2082
订阅          : nginx 443(Basic Auth) + <tailscale-ip>:8080(内网) + acme.sh 自动续期
加固          : 密码登录禁用 / fail2ban(sshd) / iptables INPUT DROP + tailscale0 放行
```

**自查要点**：
- [ ] 5 个协议端口全部在 LISTEN
- [ ] `iptables -S INPUT` 里能看到 `-i tailscale0 -j ACCEPT`
- [ ] `iptables -t nat -S PREROUTING` 里能看到端口跳跃 DNAT
- [ ] `sshd -T | grep passwordauthentication` 为 `no`
- [ ] 证书 `openssl x509 -enddate` 剩余 > 30 天，且续期 cron 存在
- [ ] 订阅三种格式都能返回 200
