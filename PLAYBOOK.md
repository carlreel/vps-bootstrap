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
| 9 | **境外 DoH 的 443 被阻断** | 国内网站加载卡几十秒；`nameserver` 写了 `https://1.1.1.1/dns-query` | UDP 53 通（65–221ms），但 DoH over 443 超时。DNS 一律改国内：`223.5.5.5` / `doh.pub` / `114.114.114.114` |
| 10 | **「ping 通节点 ≠ 能用」** | 节点延迟正常，客户端却打不开境外网站 | ping 只证明能到达服务器。DNS 解析失败的表现与「节点不通」完全一样，但排查方向相反。先查客户端 DNS，再怀疑节点 |

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

---

## 8. 环境漂移：网络条件会变，上次的结论不能沿用

**最容易犯的错**：把上一次会话的封锁结论当事实。运营商换一个 CGNAT 出口，整套策略就反转。

### 8.1 每次复诊的第一条命令：确认「现在的」出口 IP

```powershell
# 必须不走代理，否则查到的是代理 IP，会误判
(Invoke-RestMethod 'https://api.ipify.org?format=json').ip
```

记进环境清单。**IP 段变了 → 上一轮所有「什么被封 / 什么能通」的结论全部作废，重测。**

### 8.2 三段探测：分清「IP 被封 / 端口被封 / 域名被封」

| 层 | 命令 | 判读 |
|---|---|---|
| L3 ICMP | `ping -n 4 <IP>` | 通 ≠ 业务通，只说明路由可达 |
| L4 TCP | `Test-NetConnection <IP> -Port 443` | OPEN = 没被丢；TIMEOUT = 端口级或整 IP 丢弃 |
| L7 TLS | `curl -sv https://<域名>/` | **TCP 通但 `Recv failure: Connection was reset` = SNI 域名词黑名单** |

**SNI 对照法**（定位「域名被墙」唯一可靠的办法）：同一个 CF IP，只换 SNI 看 TLS 是否成功。

```powershell
foreach ($sni in 'cloudflare-ech.com','www.baidu.com','<你的argo域名>') {
  & curl.exe -s -o NUL -w "code=%{http_code} tls=%{time_appconnect}s" --max-time 10 --http1.1 `
    --resolve "$sni:443:104.18.10.118" "https://$sni/"
}
```

| 结果组合 | 结论 |
|---|---|
| 正常域名成功、你的域名 RST | **域名进了 SNI 黑名单** → 换域名，不是换 IP |
| 所有 SNI 都 RST | IP 被干扰 → 换 IP / 换 CDN 出口 |
| 所有 SNI 都超时 | TCP 被封 → 走 CDN 或 UDP |

### 8.3 Argo 域名被 SNI 阻断的完整修复（实测约 12 分钟）

1. Cloudflare 后台 → **Zero Trust → Networks → Tunnels** → 该隧道 → **Public Hostname** → Add a public hostname
2. 新子域填 `www.<你的域>`（或任意没用过的名字），Service 保持 `HTTP` → `localhost:2082`
3. 旧 hostname 留着无害，但订阅**必须全部改指向新域名**
4. 服务器上替换（**四处都要改，漏一个就是半失效**）：

```bash
cd /etc/s-box && TS=$(date +%Y%m%d-%H%M%S)
for f in sbox.json clmi.yaml sbargoym.log; do
  cp "$f" "$f.bak-$TS"
  python3 - "$f" '<旧域名>' '<新域名>' <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
print(f"  {p}: {s.count(old)} 处")
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s.replace(old, new))
PY
done
grep -c '<旧域名>' sbox.json clmi.yaml    # 应为 0
```

5. 验证（**必须是 101，不是 200**）：

```bash
curl -s -o /dev/null -w "%{http_code}\n" --http1.1 \
  -H "Host: <新域名>" -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "https://<新域名>/<ws-path>"
```

6. 客户端拉一次订阅，用**内核实测**延迟，不要只看客户端 UI 的红绿

**别试 domain fronting**：SNI 填 `cloudflare-ech.com` + `Host: <argo域名>` → Cloudflare 直接 **403**（实测），这条路在 CF 上封死。

### 8.4 UDP 到底有没有到达服务器（tcpdump 判据）

```bash
# 服务器端先起，窗口 10 秒
timeout 10 tcpdump -i eth0 -n "udp and (port 22047 or port 27567 or port 41641)" | head -40
```

```powershell
# 本机另开窗口同时发包
$u = New-Object System.Net.Sockets.UdpClient
$ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('<IP>'), 22047)
$b = [Text.Encoding]::ASCII.GetBytes('probe-' + ('x' * 40)); $u.Send($b, $b.Length, $ep)
```

判读要点：

- **tcpdump 在 AF_PACKET 层，早于 iptables**：看到入站包 = 网络真的送到了；看不到 = 中间被丢
- QUIC 服务端对乱码包**不一定回包**（hy2 不回、tuic 会回 Version Negotiation）→ 别用「没回包」判定不通
- 实测同一出口可以一个端口通、一个端口丢（27567 通，22047 与 41641 丢）→ UDP 策略按端口/五元组做，不是全封

### 8.5 Tailscale 的坏状态

| 症状 | 原因 | 处理 |
|---|---|---|
| `unexpected state: NoState` / "Tailscale is starting" | 客户端状态机没起来（服务在跑但没登录态） | 重启客户端 GUI / 服务；仍不行 `tailscale up --accept-dns=false` 重走一次 |
| `Relay=hkg` ↔ `Relay=lax`，`CurAddr` 空 | **打洞失败，走 DERP 中继** | UDP 41641 被丢必然如此；能连但慢，只当管理通道 |
| 完全连不上 | 出口 UDP 全封 | 放弃 Tailscale，用公网 SSH（22 若通） |

### 8.6 2026-11-24 复盘：封锁整体反转

| 项 | 11-20 | 11-24 |
|---|---|---|
| 本机出口 IP | `54.46.106.13` | `111.58.230.68`（移动重新分配 CGNAT） |
| VPS TCP 22/443/2082/30424/51548 | 全部 TIMEOUT | **全部 OPEN** |
| UDP 22047 / 41641 | 通 | 丢包（探测包 0 到达） |
| UDP 27567 | 通 | 仍通 |
| 实测延迟 | hy2/tuic 快 | hy2 2.1s / tuic 1.3s / vless 1.8s（都在 1–3 秒） |
| 唯一坏的 | — | **Argo 域名 `aaa.aptic.cc.cd` 被 SNI 阻断** |

教训：

1. **「封 TCP」和「封 UDP」都可能，取决于当前出口 IP**，不是 VPS 的属性
2. 上次标「❌ 不可用」的协议，下次可能全绿；反之亦然。**协议可用性表必须带日期 + 出口 IP**
3. 用户说「某些节点报错」时，先用**内核实测**（Clash API `/proxies/<name>/delay`）复现，别凭客户端 UI 的红字下结论
4. 修完把新域名写回 `/root/.vps-bootstrap/state.env` 的 `R_ARGO_DOMAIN`，否则下一个接手的 AI 会按旧域名排查
