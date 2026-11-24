# vps-bootstrap —— VPS 自建代理编排手册

> **给 AI 读的操作手册。** 配套脚本：`vps-bootstrap.sh`
> 目标：替代 / 超越 `sing-box-yg (sb)` 脚本，覆盖「从一台空服务器到订阅可用」的全流程，且不重犯已知的 9 个坑。

---

## 0. 心智模型（先理解这个，再动手）

这套东西是**三层**，不是"一个脚本"：

| 层 | 载体 | 谁读 | 作用 |
|---|---|---|---|
| **状态层** | `/root/.vps-bootstrap/state.env` | AI + 人 | 持久化「做到第几步」，跨会话不丢 |
| **执行层** | `vps-bootstrap.sh <cmd>` | AI 调用 / 人执行 | 幂等分步操作，每步自校验 |
| **判断层** | 本文档 | **只有 AI 读** | 决策树、失败分支、禁止事项 |

**为什么不是 sb 那种纯菜单**：菜单只能表达 if-else，无法表达「境外能连但本地不能 → 是 IP 级封锁 → 该走 UDP」这类推理。判断必须在 AI 侧，执行必须在脚本侧。

---

## 0.5 阶段零：还没连上服务器时（最先遇到，最容易被糊弄过去）

用户第一句通常是：

> 我买了台 VPS，IP 是 `x.x.x.x`，root 密码 `xxx`，但 SSH 连不上，怎么回事。

**此时不要问「你装了什么」——什么都还没装。** 要做的是**自己跑探测拿数据**，而不是让用户猜。

### 执行序列（AI 自己跑，不要甩给用户）

**① ICMP 存活**
```powershell
Test-Connection -ComputerName <IP> -Count 4
```
- 4/4 通 → 主机活着，进入 ②
- 全超时 → 等 3–5 分钟（cloud-init 还没跑完）；仍不通 → 让用户看面板电源状态

**② 本地 TCP 22（8 秒超时，区分 OPEN / TIMEOUT / REFUSED）**
```powershell
$c = New-Object System.Net.Sockets.TcpClient
$t = $c.BeginConnect('<IP>', 22, $null, $null)
if ($t.AsyncWaitHandle.WaitOne(8000)) { 'OPEN' } else { 'TIMEOUT' }
$c.Close()
```

**③ 境外节点测同一端口（关键对照）**
```powershell
$h = @{'Accept'='application/json'}
$r = Invoke-RestMethod "https://check-host.net/check-tcp?host=<IP>:22&max_nodes=5" -Headers $h
Start-Sleep 10
$res = Invoke-RestMethod "https://check-host.net/check-result/$($r.request_id)" -Headers $h
$res.PSObject.Properties | ForEach-Object { "$($_.Name) -> $($_.Value[0].time)" }
```

### 判定表

| 本地 22 | 境外 22 | 结论 | 下一步 |
|---|---|---|---|
| OPEN | OPEN | 网络通，是**认证**问题 | 直接连；密码不行就换密钥 |
| TIMEOUT | OPEN | **本地线路封 TCP** | 走「阶段零·B」 |
| TIMEOUT | FAIL | **服务器侧没起** | 面板 VNC 看 sshd |
| REFUSED | — | 端口没监听 | VNC |

**如果判定为「本地封 TCP」，立刻补测一件事：换端口是否也通。**

```powershell
foreach ($p in 22,443,8443,2222,8080) { 测 <IP>:$p }
```
- **全 TIMEOUT** → 是 **IP 级封锁**，换端口无效，必须走 UDP / 中继
- 个别 OPEN → 是端口级封锁，换端口即可

### 阶段零·B：确认 UDP 是否还活着

最快的验证不是扫端口，而是**直接装 Tailscale 看能否 `direct` 打洞**：
- 能 `direct` = UDP 通 = 走**路线 ②**（UDP 协议 + Tailscale 保命）
- 只能 `relay` = UDP 被限 = 走**路线 ③**（Cloudflare 中继或中转机）

**更省事的前置验证**：让用户用**手机 5G 热点**连一次 SSH。
- 热点能连 = 确认是家宽出口被封（手机走不同出口）
- 热点也不能 = IP 层面被封

### 阶段零·C：把编排器送进服务器

一旦有任意通道（SSH 直连 / Tailscale / VNC），立刻部署：

```bash
# 方式一：服务器直接拉（仓库 public 时最省事，推荐）
curl -fsSL https://raw.githubusercontent.com/carlreel/vps-bootstrap/main/vps-bootstrap.sh -o /root/vps-bootstrap.sh
chmod +x /root/vps-bootstrap.sh

# 方式二：AI 从本机 scp
scp vps-bootstrap.sh root@<IP>:/root/
```

然后 `bash /root/vps-bootstrap.sh status` 进入正式流程。

### 这一阶段最容易犯的错

- ❌ 一上来就问「你是不是防火墙没开」——什么都还没装，问不出东西
- ❌ 相信用户说的「端口被封」，不验证 → 可能其实是 sshd 没起
- ❌ 本地测一次超时就下结论 → **必须用境外节点做对照**，否则分不清「服务器问题」和「线路问题」
- ❌ 直接让用户装 Tailscale 而不先确认 UDP 通不通 → 可能装完还是 relay

---

## 1. 开场：必须问用户的 5 件事

**不要猜，不要用默认值蒙混。** 缺哪个问哪个：

| # | 信息 | 用途 | 用户没有时怎么办 |
|---|---|---|---|
| 1 | **VPS 的 IP / root 密码** | 首次登录 | 让他看开通信邮件 |
| 2 | **客户端在什么网络**（移动/联通/电信/公司网） | 决定封锁模式和协议选型 | 必须问，这是路线判断的核心输入 |
| 3 | **域名 + DNS 在哪托管** | 证书 + Argo | 没有域名 → 只能自签 + 放弃 Argo |
| 4 | **是否用 Cloudflare 账号** | Argo 隧道 | 没有 → 跳过第 6 步 |
| 5 | **客户端工具**（Clash Verge / v2rayN / Shadowrocket…） | 订阅格式 | 默认给三种全出 |

**额外主动索取**（到了对应步骤再要，别一上来全问）：
- Tailscale authkey（第 2 步）
- Cloudflare Tunnel token（第 6 步）

---

## 2. 决策树：先判路线，再装软件

```
第 1 步 network → 拿到 4 个数据点：
    A. 服务器本机 22 在监听？
    B. 客户端 ping 通？
    C. 客户端 TCP 22 通？
    D. 境外节点测 IP:22 通？
```

| A | B | C | D | 结论 | 路线 |
|---|---|---|---|---|---|
| ✓ | ✓ | ✓ | ✓ | 一切正常 | **①** 直连可用 |
| ✓ | ✓ | ✗ | ✓ | **IP 级 TCP 封锁** | **②** UDP + Tailscale |
| ✓ | ✗ | ✗ | ✓ | 同上（ICMP 也被限） | **②** |
| ✓ | ✓ | ✗ | ✗ | sshd 没起 / 云防火墙 | 用面板 VNC |
| ✗ | — | — | — | 服务没起 | VNC 排查 |

**路线②的特征（最多见）**：ICMP 通（延迟可能 400ms+）、**该 IP 所有 TCP 端口 SYN 无响应**、UDP 正常。

**路线②的强制要求**：
- 协议只选 **hysteria2 / TUIC**（UDP）
- 必须先做 Tailscale（否则会锁死自己）
- Argo 是唯一的 TCP 出路

---

## 3. 八个步骤

> 每步都是 `bash vps-bootstrap.sh <cmd>`，可单独跑、可重跑。
> 状态存在 `state.env`，`status` 随时看进度。

### 步骤 1 · network
```bash
bash vps-bootstrap.sh network
```
- **AI 要做**：拿到输出后，让用户用 `check-host.net` 测 `IP:22`
- **判据**：见上方决策树
- **完成标志**：`STEP_NETWORK=done`，并记下路线

### 步骤 2 · tailscale（保命通道，路线②必做）
```bash
bash vps-bootstrap.sh tailscale key=tskey-auth-xxxxx
```
- **AI 要做**：先向用户要 authkey（`https://login.tailscale.com/admin/settings/keys`，勾 Reusable）
- **脚本做**：装 tailscaled → `tailscale up` → 关掉 Tailscale SSH（避免每次连都要浏览器确认）
- **验证**：用户从客户端 `ssh root@100.x.y.z` 能进
- ⚠️ **这一步不通过，绝不往下走**

### 步骤 3 · singbox（引导式）
```bash
bash vps-bootstrap.sh singbox
```
- **AI 要做**：把脚本打印的引导发给用户，让他手动跑 sb 的交互安装
- **为什么不能全自动**：sb 是交互式菜单，且会问一堆选项
- ⚠️ **关键提醒**：安装时如果 sb 问防火墙，**选"暂不配置"**，统一由第 8 步处理（否则会把 tailscale0 拦掉）
- **验证**：`systemctl is-active sing-box` + `sb.json` 里有 5 个 inbound

### 步骤 4 · cert（本次最大的坑区）
```bash
bash vps-bootstrap.sh cert domain=xxx.example.com
```
- **AI 要做**：先向用户要域名；提醒「Cloudflare 代理必须关掉（改仅 DNS）」
- **脚本做**（对照 sb 的错误，逐条修正）：
  1. 校验域名解析是否指向本机
  2. `acme.sh --issue --standalone`（HTTP-01，LE 从境外验，不受国内封锁影响）
  3. 分发到 `/etc/s-box/` 和 `/root/ygkkkca/` 两处
  4. **写 `/root/ygkkkca/ca.log`** ← sb 只认这个文件，不写就误判"未申请证书"
  5. 计算 SHA256 指纹
  6. **批量修复客户端文件**：`sni=www.bing.com` → 真域名；`pinSHA256=旧值` → 新指纹；`skip-cert-verify: true` → `false`
  7. 装续期钩子（续期后自动 `restart sing-box` + `reload nginx`）
  8. 用 `openssl s_client` 验证 TLS 链
- ⚠️ **只有 hysteria2 / TUIC / anytls 能吃域名证书**；vless-reality 用的是 REALITY 伪装域名，**不要动**

### 步骤 5 · hopping（端口跳跃）
```bash
bash vps-bootstrap.sh hopping range=30000:35000
```
- **脚本做**：冲突预检（扫 `ss -lnu`）→ 清旧 DNAT → 加新 DNAT（v4+v6）→ 更新节点文本的 `mport` → 持久化
- **AI 要做**：如果预检报冲突，换一个段（如 `40000:45000`）再跑
- **验证**：`iptables -t nat -S PREROUTING | grep DNAT`

### 步骤 6 · argo（Cloudflare 隧道）
```bash
bash vps-bootstrap.sh argo token=eyJh...
```
- **AI 要做**：向用户要 Tunnel token；装完后**必须指导他配 Public Hostname**
- **必须由用户手动配的（AI 做不到）**：
  ```
  Zero Trust → Networks → Tunnels → 该隧道 → Public Hostname → Add
    Service : HTTP   ← 必须 HTTP
    URL     : localhost:2082
  ```
- ⚠️ **本次的核心坑**：填成 `HTTPS` → cloudflared 对明文后端做 TLS 握手 → 日志报 `tls: first record does not look like a TLS handshake` → 502
- **验证方法（必须用完整 WS 头 + `--http1.1`）**：
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" --http1.1 \
    --resolve <域名>:443:<CF_IP> -H "Host: <域名>" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://<域名>/<ws-path>"
  # 期望 101；400 + "bad Upgrade header" 说明链路通但头不全；502 说明回源失败
  ```

### 步骤 7 · subscription（nginx 安全订阅）
```bash
bash vps-bootstrap.sh subscription user=sub pass=<可选>
```
- **脚本做**：装 nginx + htpasswd → 443 SSL + Basic Auth → **额外开一个只绑 Tailscale IP 的 8080** → 杀 busybox httpd → 清 crontab
- **为什么要有 8080**：路线②下公网 443 从国内也拉不到，Tailscale 入口是唯一能"未连代理时拉订阅"的通道
- **验证**：无密码 401 / 带密码 200
- **交付给用户**：三种订阅链接（YAML / TXT / JSON），带内嵌账号密码

### 步骤 8 · harden（加固）
```bash
bash vps-bootstrap.sh harden
```
- **顺序铁律**：先确认 `authorized_keys` 存在 → 再禁密码
- **脚本做**：写 `99-vbs-hardening.conf` → 改 `50-cloud-init.conf` → `sshd -t` → 重启 → 回读 `sshd -T` 最终值 → fail2ban → iptables（**必放行 `-i tailscale0`**）→ 持久化
- ⚠️ **绝不清 `nat` 表**（会毁掉端口跳跃）
- **验证**：用户新开终端能密钥登录、密码被拒

---

## 4. AI 做不了的事（必须明确指出，不要假装能做）

| 事项 | 原因 | 怎么让用户做 |
|---|---|---|
| 首次登录（SSH 不通时） | 需要浏览器 VNC | 给面板截图级步骤 |
| 跑 sb 的交互安装 | 纯 TTY 交互 | 贴引导文本 |
| Cloudflare 后台配 ingress | 云端 Web 控制台 | 给出字段名和正确值 |
| 用户客户端的账号密码/私钥配置 | 在本机 | 给「字段表」让用户照填 |
| 判断用户网络封锁模式 | 需要从客户端测 | 给 check-host 链接 |

**原则**：说清「我需要你做 X，因为 Y」，并给出可照抄的字段/命令。不要含糊其辞。

---

## 5. 失败排查速查

| 症状 | 最可能原因 | 处置 |
|---|---|---|
| `ssh` 超时但境外能连 | IP 级 TCP 封锁 | 走路线②，别换端口 |
| Tailscale 显示 `relay` 而非 `direct` | UDP 被限 / 路由劫持 | 查 `ip rule`，见坑 5 |
| 装完 WARP 后全断 | warp-go 改策略路由 | `systemctl stop warp-go && disable` |
| acme-yg 说有证书、sb 说没有 | 缺 `ca.log` | `echo 域名 > /root/ygkkkca/ca.log` |
| 换证书后 TLS 节点全挂 | SNI/pin 未同步 | 重跑 `cert` 步骤（会批量修） |
| Argo 502 + `not look like a TLS handshake` | ingress 用了 HTTPS | 后台改 HTTP |
| Argo 403 | SNI 与 Host 不一致 | 客户端 `sni` 必须等于 ingress 的 hostname |
| 改 iptables 后失联 | 没放行 tailscale0 | 从 Tailscale 或 VNC 进去补规则 |
| nginx 订阅 401 但密码对 | `$PASSWORD` 为空 / htpasswd 未生成 | 重新 `htpasswd -bc` |
| **节点 ping 通但上不了外网** | **DNS 解析失败**（最常见） | 客户端启用「远程 DNS」/ DoH；Clash 改国内 nameserver |
| **境外 DoH 超时** | **DoH 的 443 被阻断**（UDP 53 反而通） | 全部改用 `223.5.5.5` / `doh.pub` |
| 国内网站加载卡几十秒 | `nameserver` 写了境外 DoH | 见「步骤 9 · DNS 三档配置」 |
| Karing / v2rayN 里部分节点一选就没网 | `auto` 组混了被封节点 | 订阅里只保留可用节点（或手动选 hy2/tuic） |

---

## 6. 禁止事项（sb 踩过的，别重犯）

1. ❌ **不要在没验证密钥登录的情况下禁掉密码认证**
2. ❌ **不要 `iptables -t nat -F`**（毁掉端口跳跃）
3. ❌ **不要只改 `/etc/ssh/sshd_config`**（Ubuntu 24.04 会被 `sshd_config.d/` 覆盖）
4. ❌ **不要用 `sed` 替换含 `&` 的字符串**（`&` 代表整个匹配，会写坏文件；用 Python 按行处理）
5. ❌ **不要把 Argo 的 origin 配成 HTTPS**（后端是明文）
6. ❌ **不要给 vmess-ws 开 TLS 后又指望 Argo 可用**（会打乱协议栈）
7. ❌ **不要保留 busybox httpd**（明文无密码，扫到就泄漏全部节点）
8. ❌ **不要在端口跳跃段里选已被占用的端口**（先跑冲突预检）
9. ❌ **不要相信「装完就好」**——每步必须有验证，验证不过就停

---

## 7. 常用命令

```bash
bash vps-bootstrap.sh probe            # 快速看现状（人读）
bash vps-bootstrap.sh probe --json     # 贴给 AI
bash vps-bootstrap.sh status           # 看做到第几步
bash vps-bootstrap.sh all              # 按序跑完剩余步骤
bash vps-bootstrap.sh reset cert       # 重置某步以便重跑
```

**文件位置**：
```
/root/.vps-bootstrap/state.env      # 进度
/root/.vps-bootstrap/logs/          # 各步日志
/root/.vps-bootstrap/backups/       # 改动前备份（按 时间戳 命名）
```

---

## 8. 接手已有部署（跨会话）

新对话第一次接触一台**已经装过**的机器时，按此顺序：

1. `bash vps-bootstrap.sh probe --json` → 看服务/端口/防火墙/进度
2. `bash vps-bootstrap.sh status` → 看哪些步骤已 done
3. 只补未完成的步骤，**不要重跑已完成的**（虽然幂等，但会重启服务造成短暂中断）
4. 遇到症状先查第 5 节的排查表，再动手

---

## 9. 客户端接入（服务器全绿之后的最后一公里）

**这一步最容易白忙**：服务器侧全部正常、节点 ping 通，但客户端上不了网。

### 核心判据

> **ping 通节点 ≠ 能用。**
> ping 只验证「能到达服务器」，不验证「域名能解析」。

| 症状 | 根因 | 处方 |
|---|---|---|
| 节点延迟正常，但打不开任何境外网站 | **DNS 解析失败** | 见下方 DNS 三档配置 |
| 选某些节点就完全没网 | 该节点是被封的 TCP 协议 | 只选 hy2 / tuic / argo |
| 部分网站能开、部分不能 | 分流规则命中错误 | 先切「全局」验证，再改规则 |
| hy2/tuic 不显示或报协议错误 | 客户端内核不支持 | 换 sing-box 内核 |

### DNS 三档配置

**v2rayN**
```
设置 → 参数设置 → 核心基础设置 → 内核：sing-box（Xray 不支持 hy2/tuic）
设置 → DNS 设置 → ✅ 使用远程 DNS
DNS 服务器：https://223.5.5.5/dns-query
```

**Karing**
```
优先用 TXT 订阅（JSON 对 sing-box 内核版本敏感）
设置 → DNS → 启用 DoH：https://223.5.5.5/dns-query
```

**Clash Verge / Mihomo**（订阅 YAML 里写）
```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - "https://223.5.5.5/dns-query"
    - "https://doh.pub/dns-query"
    - "114.114.114.114"
  nameserver-policy:
    "geosite:cn,private": ["223.5.5.5", "119.29.29.29"]
```

### ⚠️ 关键坑：DoH 的 443 被阻断，UDP 53 反而通

中国移动家宽实测：

| 目标 | 协议 | 结果 |
|---|---|---|
| `8.8.8.8` | UDP 53 | ✅ 65 ms |
| `1.1.1.1` | UDP 53 | ✅ 221 ms |
| `https://1.1.1.1/dns-query` | **DoH / 443** | ❌ 超时 |
| `https://8.8.8.8/dns-query` | **DoH / 443** | ❌ 超时 |

**规则**：DNS 配置里**永远不要写境外 DoH**。国内 DoH（`223.5.5.5` / `doh.pub`）稳定可达。

fake-ip 模式下，境外域名解析成 `198.18.x.x`，真实 IP 由节点端解析——**本地根本不需要能访问境外 DNS**。

### 验证方法

**Clash 看规则命中**：左侧「连接」页 → 每条连接会显示命中规则
- 国内域名显示 `DIRECT` = 正确
- 国内域名显示节点名 = 规则没生效，流量绕了代理

**对比 DNS 速度**：
```powershell
Measure-Command { Resolve-DnsName www.baidu.com -Server 223.5.5.5 }
Measure-Command { Resolve-DnsName www.baidu.com -Server 1.1.1.1 }   # 若用 DoH 则测 https://1.1.1.1/dns-query
```

### 节点可用性速查（**带条件，会随出口 IP 变**）

⚠️ 下表是 **2026-11-20，出口 IP `54.46.106.13`（移动 CGNAT）** 的结论。2026-11-24 出口换成 `111.58.230.68` 后整套反转：TCP 全通、UDP 被限、只有 Argo 域名被封。**用之前先测当前出口 IP，别照抄。**

| 协议 | 传输层 | 11-20 那天 | 备注 |
|---|---|---|---|
| hysteria2 | UDP/QUIC | ✅ | 配合端口跳跃 |
| TUIC v5 | UDP/QUIC | ✅ | |
| vmess-ws + CDN | TCP 443 → CF | ✅ | 需 ingress 配对 + 域名没被封 |
| vless-reality | TCP | ❌ | 不能套 CDN；11-24 已恢复 |
| vmess-ws 直连 | TCP | ❌ | 11-24 已恢复 |
| anytls | TCP | ❌ | 无 UDP 变体 |

**给用户的建议**：订阅里同时保留 UDP 系（hy2/tuic）、CDN 系（argo）和直连系各一个，**环境一变总有一个活着**；不要只留一类。

---

## 10. 复诊 / 接手已在运行的部署（用户报错时第一件事）

**先跑这三条，再谈别的**（细节见 PLAYBOOK 第 8 节）：

```powershell
(Invoke-RestMethod 'https://api.ipify.org?format=json').ip          # 1. 当前出口 IP（不走代理）
Test-NetConnection <VPS_IP> -Port 22                                 # 2. 直连是否恢复
& 'C:\Program Files\Tailscale\tailscale.exe' status                  # 3. 保命通道
```

判定：

- 出口 IP 与上次记录**不同** → 封锁结论全部作废，重新分类
- TCP 22 **OPEN** → 用 `ssh root@<IP>` 直连，别绕 Tailscale
- TCP 22 **TIMEOUT** → 回到路线②，走 Tailscale / CDN

### 10.1 用内核实测，别信客户端 UI

```powershell
# 起独立 mihomo 实例，不动用户正在用的那个
& 'C:\Program Files\Clash Verge\verge-mihomo.exe' -d <dir> -f <cfg>
# 先校验配置
& 'C:\Program Files\Clash Verge\verge-mihomo.exe' -d <dir> -f <cfg> -t
# 逐节点测（url 必须用国内可达的 204）
Invoke-RestMethod "http://127.0.0.1:<ctrl>/proxies/<name>/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=8000" -Headers @{Authorization='Bearer <secret>'}
```

最小配置骨架（复制即用，只换 proxies）：

```yaml
mixed-port: 17897
mode: rule
log-level: warning
external-controller: 127.0.0.1:19097
secret: probe
dns:
  enable: true
  default-nameserver: ["223.5.5.5"]
  nameserver: ["223.5.5.5", "119.29.29.29"]
proxies: []
rules:
  - MATCH,DIRECT
```

> 用 `verge-mihomo.exe` 而不是用户自己的配置目录，避免覆盖他正在用的 Clash 配置。测完 `Stop-Process`。

### 10.2 四个高频复诊结论

| 现象 | 根因 | 动作 |
|---|---|---|
| TCP 全 TIMEOUT | 当前出口对该 IP 丢包 | 走 CDN / Tailscale / UDP |
| TCP 通，但所有节点 >1.5s | 出口 QoS 限速 | 端口跳跃；换协议；换 CDN |
| **单节点 ERR，TCP 通，同 IP 换 SNI 正常** | **域名被 SNI 封锁** | 换 hostname（PLAYBOOK 8.3） |
| Tailscale `NoState` / Relay 不同城 | 客户端没起 / 打洞失败 | 重启客户端；只当管理通道 |

### 10.3 修完必须回写状态

```bash
# 服务器：让下一个接手的 AI 看到正确域名
cd /root/.vps-bootstrap && sed -i 's/^R_ARGO_DOMAIN=.*/R_ARGO_DOMAIN=<新域名>/' state.env
# 本地仓库：更新 PLAYBOOK 第 8.6 节的复盘表（日期 + 出口 IP + 结论）
```

**否则下一个 AI 会按旧域名、旧封锁结论排查，浪费一整轮。**
