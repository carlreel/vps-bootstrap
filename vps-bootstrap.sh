#!/usr/bin/env bash
# ============================================================================
# vps-bootstrap.sh v1.0 —— VPS 自建代理编排器
#
# 设计目标：替代 / 超越 sing-box-yg (sb) 脚本
#   · 状态机：每步幂等、可重入、失败可重跑
#   · 前置检查 + 后置验证：不验证完不算完成
#   · 端口冲突预检：绝不撞掉已有服务
#   · 双输出：人类可读 + AI 可读（--json）
#   · 绝不自作主张：缺参数直接报错并给出获取方式
#
# 用法：
#   bash vps-bootstrap.sh <command> [key=value ...]
#
# 命令：
#   probe                           只读环境探针
#   status                          显示各步骤进度
#   network                         网络诊断与路线决策
#   tailscale key=tskey-auth-xxx    安装并加入 tailnet（保命通道）
#   singbox [mode=1|2|3]            安装 sing-box（引导执行 sb 交互脚本）
#   cert domain=example.com         申请证书并分发到各节点
#   hopping [range=30000:35000]     配置 hysteria2 端口跳跃
#   argo token=eyJh...              安装 Cloudflare Tunnel 并校验
#   subscription [user=sub] [pass=x] 部署 nginx 安全订阅
#   harden                          防火墙 + SSH 加固
#   all                             按序执行所有未完成步骤
#   reset [step]                    清除某步状态以便重跑
# ============================================================================

set -uo pipefail

ROOT=/root/.vps-bootstrap
STATE=$ROOT/state.env
LOGS=$ROOT/logs
BACKUPS=$ROOT/backups
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$ROOT" "$LOGS" "$BACKUPS"
touch "$STATE"

# ── 颜色 ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; N='\033[0m'; D='\033[2m'
else
  R=''; G=''; Y=''; B=''; N=''; D=''
fi

say()  { printf "${B}▸${N} %s\n" "$*"; }
ok()   { printf "${G}✓${N} %s\n" "$*"; }
warn() { printf "${Y}!${N} %s\n" "$*"; }
err()  { printf "${R}✗${N} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }
asroot() { [ "$(id -u)" = "0" ] || die "需要 root 权限"; }

# ── 状态机 ──────────────────────────────────────────────────────────────
source "$STATE" 2>/dev/null || true

state_set() {
  local k=$1 v=$2
  grep -v "^${k}=" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  echo "${k}=${v}" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  export "$k=$v"
}

state_get() { eval "echo \${$1:-}"; }

# ── 参数解析 ────────────────────────────────────────────────────────────
declare -A ARG
for a in "$@"; do
  case "$a" in
    *=*) ARG["${a%%=*}"]="${a#*=}" ;;
  esac
done
opt() { echo "${ARG[$1]:-${2:-}}"; }

need_arg() {
  local k=$1 hint=$2
  local v
  v=$(opt "$k")
  [ -n "$v" ] || die "缺少参数 ${k}=<值>。
  获取方式：${hint}
  示例：bash $0 ${CMD} ${k}=<你的值>"
  echo "$v"
}

# ── 通用工具 ────────────────────────────────────────────────────────────
backup() {
  local f=$1
  [ -f "$f" ] || return 0
  local b="$BACKUPS/$(echo "$f" | tr '/' '_').${TS}"
  cp -a "$f" "$b" && echo "$b"
}

# 端口是否被占用（tcp|udp）
port_busy() {
  local p=$1 proto=${2:-tcp} flag=L
  [ "$proto" = "udp" ] && flag=U
  ss -ln${flag}H 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
}

# 端口段内是否有监听
range_busy() {
  local lo=$1 hi=$2 proto=${3:-udp} flag=L
  [ "$proto" = "udp" ] && flag=U
  ss -ln${flag}H 2>/dev/null | awk '{print $4}' \
    | grep -oE '[0-9]+$' | awk -v lo="$lo" -v hi="$hi" '$1>=lo && $1<=hi {print; found=1} END{exit !found}'
}

pub_ip4() { timeout 8 curl -s -4 https://ifconfig.co 2>/dev/null || true; }

svc_active() { systemctl is-active "$1" 2>/dev/null || echo absent; }

# ══════════════════════════════════════════════════════════════════════
# probe —— 只读探针
# ══════════════════════════════════════════════════════════════════════
cmd_probe() {
  local json=${1:-}
  local v4 v6 os k
  v4=$(pub_ip4); v6=$(timeout 8 curl -s -6 https://ifconfig.co 2>/dev/null || true)
  os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"); k=$(uname -r)

  local tcp udp fw_mode ts_acc
  tcp=$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -nu | tr '\n' ' ' | sed 's/ $//')
  udp=$(ss -lnuH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -nu | tr '\n' ' ' | sed 's/ $//')
  fw_mode=$(iptables -S INPUT 2>/dev/null | grep -c '^-A INPUT -j DROP' || true)
  ts_acc=$(iptables -S INPUT 2>/dev/null | grep -c '^-A INPUT -i tailscale0 -j ACCEPT' || true)

  if [ "$json" = "--json" ]; then
    cat <<EOF
{"host":"$(hostname)","os":"$os","kernel":"$k","v4":"${v4:-}","v6":"${v6:-}",
 "services":{"sing-box":"$(svc_active sing-box)","nginx":"$(svc_active nginx)","cloudflared":"$(svc_active cloudflared)","tailscaled":"$(svc_active tailscaled)","fail2ban":"$(svc_active fail2ban)"},
 "listen":{"tcp":"$tcp","udp":"$udp"},
 "firewall":{"drop_rule":$fw_mode,"tailscale_iface":$ts_acc},
 "steps":{"network":"$(state_get STEP_NETWORK)","tailscale":"$(state_get STEP_TAILSCALE)","singbox":"$(state_get STEP_SINGBOX)","cert":"$(state_get STEP_CERT)","hopping":"$(state_get STEP_HOPPING)","argo":"$(state_get STEP_ARGO)","subscription":"$(state_get STEP_SUBSCRIPTION)","harden":"$(state_get STEP_HARDEN)"}}
EOF
    return 0
  fi

  printf "${B}════ VPS BOOTSTRAP · PROBE ════${N}\n"
  printf "  %s / %s / kernel %s\n  v4: %s  v6: %s\n" "$(hostname)" "$os" "$k" "${v4:-none}" "${v6:-none}"
  printf "\n${B}[服务]${N}\n"
  for s in sing-box nginx cloudflared tailscaled fail2ban; do
    a=$(svc_active "$s"); [ "$a" = active ] && ok "$s" || printf "  ${D}·${N} %-12s %s\n" "$s" "$a"
  done
  printf "\n${B}[端口]${N}\n  TCP: %s\n  UDP: %s\n" "${tcp:-none}" "${udp:-none}"
  printf "\n${B}[防火墙]${N}\n"
  [ "$fw_mode" -gt 0 ] && ok "白名单+DROP 已启用" || warn "无 DROP 兜底（未加固）"
  [ "$ts_acc" -gt 0 ] && ok "tailscale0 已放行" || err "tailscale0 未放行（会切断保命通道）"
  printf "\n"
}

# ══════════════════════════════════════════════════════════════════════
# status —— 进度视图
# ══════════════════════════════════════════════════════════════════════
cmd_status() {
  printf "${B}════ 部署进度 ════${N}\n"
  local steps="network:1.网络诊断 tailscale:2.保命通道 singbox:3.sing-box cert:4.证书 hopping:5.端口跳跃 argo:6.Argo隧道 subscription:7.订阅 harden:8.加固"
  for pair in $steps; do
    local k=${pair%%:*} label=${pair#*:}
    local v; v=$(state_get "STEP_$(echo "$k" | tr '[:lower:]' '[:upper:]')")
    if [ "$v" = "done" ]; then
      printf "  ${G}✓${N} %-22s %s\n" "$label" "$(state_get "R_$(echo "$k" | tr '[:lower:]' '[:upper:]')")"
    else
      printf "  ${D}○${N} %-22s ${D}pending${N}\n" "$label"
    fi
  done
  printf "\n  状态文件: %s\n  日志目录: %s\n  备份目录: %s\n\n" "$STATE" "$LOGS" "$BACKUPS"
}

# ══════════════════════════════════════════════════════════════════════
# network —— 网络诊断与路线决策
# ══════════════════════════════════════════════════════════════════════
cmd_network() {
  asroot
  say "检测本机出站与监听状态"

  local v4; v4=$(pub_ip4)
  [ -n "$v4" ] || die "无法获取公网 IPv4，检查网络"

  local tcp22
  ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE '[:.]22$' \
    && tcp22=yes || tcp22=no

  printf "\n  公网 IPv4      : %s\n" "$v4"
  printf "  本机 22 端口   : %s\n" "$tcp22"

  printf "\n${Y}接下来需要你从【客户端】测三项，请把结果告诉我：${N}\n"
  printf "  1) ping %s                      → 通 / 不通\n" "$v4"
  printf "  2) 客户端直连 %s:22              → 通 / 超时\n" "$v4"
  printf "  3) 用在线工具测 %s:22 是否 OPEN\n" "$v4"
  printf "     https://check-host.net/check-tcp?host=%s:22\n" "$v4"
  printf "\n  判据：\n"
  printf "    · 境外 OPEN + 你超时  → 路线②：IP级TCP封锁，走UDP协议 + Tailscale\n"
  printf "    · 境外也不过         → sshd/云防火墙问题，用面板 VNC 排查\n"
  printf "    · 都通               → 路线①：直连可用\n"

  state_set STEP_NETWORK done
  state_set R_NETWORK "${v4}"
  ok "已记录。确认路线后继续下一步"
}

# ══════════════════════════════════════════════════════════════════════
# tailscale —— 保命通道
# ══════════════════════════════════════════════════════════════════════
cmd_tailscale() {
  asroot
  local key; key=$(need_arg key "Cloudflare 式后台 https://login.tailscale.com/admin/settings/keys 生成 Reusable auth key")

  if ! has tailscale; then
    say "安装 tailscale"
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tee -a "$LOGS/tailscale.log" | tail -3
  fi

  local hn; hn=$(hostname -s)
  say "加入 tailnet（hostname=$hn）"
  tailscale up --authkey="$key" --hostname="$hn" --accept-dns=false 2>&1 | tee -a "$LOGS/tailscale.log"
  tailscale set --ssh=false 2>/dev/null || true

  sleep 2
  local ip; ip=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$ip" ] || die "未取得 Tailscale IP，检查 authkey 是否有效"

  state_set STEP_TAILSCALE done
  state_set R_TAILSCALE "$ip"
  ok "Tailscale IP = $ip"
  printf "\n${Y}请立刻验证：从客户端 ssh root@%s 能进，再继续后续步骤${N}\n" "$ip"
}

# ══════════════════════════════════════════════════════════════════════
# singbox —— 安装 sing-box（引导交互脚本）
# ══════════════════════════════════════════════════════════════════════
cmd_singbox() {
  asroot
  if [ -x /etc/s-box/sing-box ] && systemctl is-active --quiet sing-box; then
    ok "sing-box 已安装并运行，跳过"
    state_set STEP_SINGBOX done
    return 0
  fi

  cat <<'GUIDE'
══════════════════════════════════════════════════════════════════
  需要你手动执行 sb 的交互安装（它是交互式的，无法全自动）
══════════════════════════════════════════════════════════════════
  1) 运行：  bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
  2) 选择：  1. 一键安装 Sing-box
  3) 协议：  全选默认（vless-reality / vmess-ws / hysteria2 / tuic / anytls）
  4) 完成后回到这里执行： bash vps-bootstrap.sh singbox  (验证)

  ⚠️ 安装过程中如果提示防火墙，选“暂不配置”，统一由本脚本的第 8 步处理，
     避免它把 tailscale0 拦掉导致你失联。
══════════════════════════════════════════════════════════════════
GUIDE
  state_set STEP_SINGBOX pending
}

# ══════════════════════════════════════════════════════════════════════
# cert —— 证书申请 + 分发 + 客户端字段修复
# ══════════════════════════════════════════════════════════════════════
cmd_cert() {
  asroot
  local domain; domain=$(need_arg domain "一个已解析到本机的域名，如 sub.example.com")
  has openssl || die "缺少 openssl"

  # 1. 校验域名解析
  say "校验 $domain 解析"
  local resolved; resolved=$(getent hosts "$domain" | awk '{print $1}' | head -1)
  local myip; myip=$(pub_ip4)
  if [ "$resolved" != "$myip" ]; then
    warn "域名解析到 [$resolved]，本机 [$myip] —— 继续可能失败"
    printf "  如果使用 Cloudflare 代理（橙色云），请先改成【仅 DNS】\n"
    read -r -p "  仍要继续？[y/N] " a; [ "$a" = "y" ] || return 1
  fi

  # 2. 申请
  say "申请 Let's Encrypt 证书（standalone / HTTP-01）"
  if ! [ -x /root/.acme.sh/acme.sh ]; then
    curl -fsSL https://get.acme.sh | sh 2>&1 | tail -3
  fi
  port_busy 80 tcp && die "80 端口被占用，HTTP-01 无法进行（先停占用服务）"
  /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256 \
    --server letsencrypt --force 2>&1 | tee "$LOGS/cert.log" | tail -8
  grep -q "Cert success" "$LOGS/cert.log" || die "签发失败，查看 $LOGS/cert.log"

  local CDIR=/root/.acme.sh/${domain}_ecc
  [ -f "$CDIR/fullchain.cer" ] || die "证书文件缺失"

  # 3. 分发到两处（sb 用 /etc/s-box，acme-yg 用 /root/ygkkkca）
  say "分发证书"
  mkdir -p /etc/s-box /root/ygkkkca
  backup /etc/s-box/cert.pem >/dev/null; backup /etc/s-box/private.key >/dev/null
  install -m 644 "$CDIR/fullchain.cer" /etc/s-box/cert.pem
  install -m 600 "$CDIR/${domain}.key" /etc/s-box/private.key
  install -m 644 "$CDIR/fullchain.cer" /root/ygkkkca/cert.crt
  install -m 600 "$CDIR/${domain}.key" /root/ygkkkca/private.key

  # 4. 关键：写 ca.log 让 sb 认识（sb 只认这个文件）
  echo "$domain" > /root/ygkkkca/ca.log
  ok "已写 /root/ygkkkca/ca.log（否则 sb 会误判“未申请证书”）"

  # 5. 计算指纹
  local FP; FP=$(openssl x509 -in /etc/s-box/cert.pem -noout -fingerprint -sha256 \
    | sed 's/.*=//' | tr -d ':' | tr -d ' ' | tr 'A-Z' 'a-z')
  say "证书指纹 $FP"

  # 6. 修复客户端文件里的 SNI 与 pin（sb 生成的旧值会全部失配）
  grep -rl 'www\.bing\.com' /etc/s-box/ 2>/dev/null | grep -v '\.bak' | while read -r f; do
    backup "$f" >/dev/null
    sed -i "s|sni=www\.bing\.com|sni=${domain}|g; s|sni: www\.bing\.com|sni: ${domain}|g" "$f"
  done
  grep -rl 'pinSHA256=' /etc/s-box/ 2>/dev/null | grep -v '\.bak' | while read -r f; do
    sed -i "s|pinSHA256=[0-9a-f]*|pinSHA256=${FP}|g" "$f"
  done
  grep -rl 'skip-cert-verify: true' /etc/s-box/*.yaml 2>/dev/null | while read -r f; do
    backup "$f" >/dev/null
    sed -i 's|skip-cert-verify: true|skip-cert-verify: false|g; s|disable-sni: true|disable-sni: false|g' "$f"
  done

  # 7. 续期钩子
  /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
    --key-file /etc/s-box/private.key \
    --fullchain-file /etc/s-box/cert.pem \
    --reloadcmd "systemctl restart sing-box 2>/dev/null; systemctl reload nginx 2>/dev/null; true" \
    2>&1 | tail -3

  # 8. 重启并验证
  systemctl restart sing-box 2>/dev/null || true
  sleep 2
  local ANYTLS_PORT; ANYTLS_PORT=$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u | while read -r p; do echo "$p"; done | grep -E '^51[0-9]{3}$' | head -1)
  if [ -n "${ANYTLS_PORT:-}" ]; then
    local verify; verify=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:"$ANYTLS_PORT" -servername "$domain" 2>/dev/null | grep -c 'Verify return code: 0')
    [ "$verify" -gt 0 ] && ok "TLS 链验证通过（端口 $ANYTLS_PORT）" || warn "TLS 验证未通过，检查 $LOGS/cert.log"
  fi

  state_set STEP_CERT done
  state_set R_CERT "$domain"
  state_set R_CERT_FP "$FP"
  ok "证书就绪：CN=$domain  指纹=$FP"
}

# ══════════════════════════════════════════════════════════════════════
# hopping —— hysteria2 端口跳跃
# ══════════════════════════════════════════════════════════════════════
cmd_hopping() {
  asroot
  local range lo hi
  range=$(opt range "30000:35000")
  lo=${range%%:*}; hi=${range##*:}

  # 目标端口：从 sb.json 读 hysteria2
  local hy2port
  if [ -f /etc/s-box/sb.json ] && has python3; then
    hy2port=$(python3 -c "
import json
d=json.load(open('/etc/s-box/sb.json'))
for i in d['inbounds']:
    if i.get('type')=='hysteria2': print(i['listen_port']); break
" 2>/dev/null)
  fi
  [ -n "${hy2port:-}" ] || die "未找到 hysteria2 端口（sb.json 未安装？）"

  # 冲突预检
  say "冲突预检：$lo-$hi (udp)"
  local conflict
  conflict=$(ss -lnuH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' \
    | awk -v lo="$lo" -v hi="$hi" '$1>=lo && $1<=hi' | tr '\n' ' ')
  if [ -n "$conflict" ]; then
    die "端口段冲突，已被占用: $conflict
  换一个段，例如 range=40000:45000"
  fi
  ok "无冲突"

  # 清理旧规则 + 写入新规则
  local old
  old=$(iptables -t nat -S PREROUTING 2>/dev/null | grep 'DNAT' | grep -oE 'dport [0-9]+:[0-9]+' | awk '{print $2}' || true)
  if [ -n "$old" ]; then
    say "移除旧跳跃规则 $old"
    iptables  -t nat -D PREROUTING -i eth0 -p udp --dport "$old" -j DNAT --to-destination :"$hy2port" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -i eth0 -p udp --dport "$old" -j DNAT --to-destination :"$hy2port" 2>/dev/null || true
  fi

  say "写入 DNAT: udp $lo:$hi -> :$hy2port"
  iptables  -t nat -A PREROUTING -i eth0 -p udp --dport "$lo:$hi" -j DNAT --to-destination :"$hy2port"
  ip6tables -t nat -A PREROUTING -i eth0 -p udp --dport "$lo:$hi" -j DNAT --to-destination :"$hy2port"

  # 更新节点文本里的 mport
  local mp="${lo}-${hi}"
  for f in /etc/s-box/hy2.txt /etc/s-box/jhdy.txt /etc/s-box/jhsub.txt; do
    [ -f "$f" ] || continue
    backup "$f" >/dev/null
    python3 - "$f" "$mp" <<'PY'
import sys, re
path, mp = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8').read().split('\n')
out = []
for ln in lines:
    if ln.startswith('hysteria2://'):
        ln = re.sub(r'(&|&amp;)mport=[^&#]*', '', ln)
        if '?' in ln:
            ln = ln.replace('?', f'?mport={mp}&', 1)
        else:
            ln = ln.replace(':22', ':22')  # no-op
    out.append(ln)
open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY
  done

  # 持久化
  has netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 && ok "已持久化"

  state_set STEP_HOPPING done
  state_set R_HOPPING "udp ${lo}:${hi} -> :${hy2port}"
  ok "端口跳跃就绪：udp $lo:$hi → :$hy2port"
}

# ══════════════════════════════════════════════════════════════════════
# argo —— Cloudflare Tunnel
# ══════════════════════════════════════════════════════════════════════
cmd_argo() {
  asroot
  local token; token=$(need_arg token "Cloudflare Zero Trust → Networks → Tunnels → 创建隧道后复制 token")

  if ! has cloudflared; then
    say "安装 cloudflared"
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq && apt-get install -y cloudflared 2>&1 | tail -2
  fi

  mkdir -p /etc/cloudflared
  backup /etc/cloudflared/token >/dev/null
  printf '%s' "$token" > /etc/cloudflared/token
  chmod 600 /etc/cloudflared/token

  cat > /etc/systemd/system/cloudflared.service <<'UNIT'
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now cloudflared
  sleep 8

  cat <<'CHECK'
══════════════════════════════════════════════════════════════════
  ⚠️ 必须在 Cloudflare 后台完成（AI 无法代做）：
  Zero Trust → Networks → Tunnels → 选择该隧道 → Public Hostname → Add
     Subdomain : aaa（或你要的名字）
     Domain    : 你的域名
     Service   : HTTP   ← 必须是 HTTP，不是 HTTPS！
     URL       : localhost:2082
  ────────────────────────────────────────────────────────────────
  为什么是 HTTP：sing-box 的 vmess-ws inbound 默认 tls.enabled=false
  （明文）。若填 HTTPS，cloudflared 会做 TLS 握手 → 报
  "tls: first record does not look like a TLS handshake" → 502。
══════════════════════════════════════════════════════════════════
CHECK
  read -r -p "配好后回车，我来验证（跳过则输入 s）: " a
  [ "$a" = "s" ] && { warn "跳过验证，稍后用  argo-verify 重试"; state_set STEP_ARGO pending; return 0; }

  local origin
  origin=$(journalctl -u cloudflared --no-pager --since "2 min ago" 2>/dev/null \
    | grep -oE 'originService=[a-z]+://[^ ]+' | tail -1 | sed 's/originService=//')
  if [ -n "$origin" ]; then
    case "$origin" in
      https://*) err "回源仍是 HTTPS —— 请回后台改成 HTTP"; state_set STEP_ARGO pending; return 1 ;;
      http://*)  ok "回源协议正确：$origin" ;;
    esac
  else
    warn "还没抓到请求日志，后台配好后访问一次再验"
  fi

  state_set STEP_ARGO done
  state_set R_ARGO "${origin:-未取到}"
  ok "Argo 隧道就绪"
}

# ══════════════════════════════════════════════════════════════════════
# subscription —— nginx 安全订阅
# ══════════════════════════════════════════════════════════════════════
cmd_subscription() {
  asroot
  local user pass domain
  user=$(opt user "sub")
  pass=$(opt pass "")
  if [ -z "$pass" ]; then
    pass=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)
    say "生成随机密码：$pass"
  fi
  domain=$(state_get R_CERT)
  [ -n "$domain" ] || die "需要先完成 cert 步骤（缺少域名）"

  export DEBIAN_FRONTEND=noninteractive
  has nginx  || apt-get install -y nginx 2>&1 | tail -2
  has htpasswd || apt-get install -y apache2-utils 2>&1 | tail -2

  mkdir -p /etc/nginx/auth
  htpasswd -bc /etc/nginx/auth/.htpasswd "$user" "$pass" >/dev/null 2>&1
  chown root:www-data /etc/nginx/auth/.htpasswd
  chmod 640 /etc/nginx/auth/.htpasswd

  # /root 权限：nginx worker 需能遍历但不可列目录
  chmod 711 /root
  [ -d /root/websbox ] && chmod -R 755 /root/websbox

  local tsip; tsip=$(state_get R_TAILSCALE)
  local subdir; subdir=$(tr -d '\r\n' < /etc/s-box/subtoken.log 2>/dev/null || echo "")

  backup /etc/nginx/sites-available/vbs >/dev/null || true
  cat > /etc/nginx/sites-available/vbs <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;
    ssl_certificate     /etc/s-box/cert.pem;
    ssl_certificate_key /etc/s-box/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    auth_basic "Subscription";
    auth_basic_user_file /etc/nginx/auth/.htpasswd;
    root /root/websbox;
    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; }
}
NGINX

  if [ -n "$tsip" ]; then
    cat >> /etc/nginx/sites-available/vbs <<NGINX
server {
    listen $tsip:8080;
    auth_basic "Subscription";
    auth_basic_user_file /etc/nginx/auth/.htpasswd;
    root /root/websbox;
    location / { try_files \$uri \$uri/ =404; }
}
NGINX
  fi

  ln -sf /etc/nginx/sites-available/vbs /etc/nginx/sites-enabled/vbs
  rm -f /etc/nginx/sites-enabled/default
  nginx -t 2>&1 | tail -3 || die "nginx 配置错误"
  systemctl enable --now nginx
  systemctl reload nginx

  # 终止 busybox httpd
  pkill -f "busybox httpd" 2>/dev/null && ok "已终止 busybox httpd" || true
  crontab -l 2>/dev/null | grep -v "busybox httpd" | crontab - 2>/dev/null || true

  # 验证
  local code401 code200
  code401=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "$domain:443:127.0.0.1" "https://$domain/$subdir/jhsub.txt")
  code200=$(curl -sk -o /dev/null -w "%{http_code}" -u "$user:$pass" --resolve "$domain:443:127.0.0.1" "https://$domain/$subdir/jhsub.txt")
  [ "$code401" = "401" ] && ok "无密码 → 401" || warn "无密码返回 $code401（期望 401）"
  [ "$code200" = "200" ] && ok "带密码 → 200" || err "带密码返回 $code200（期望 200）"

  echo "$user:$pass" > /root/sub-auth.txt
  chmod 600 /root/sub-auth.txt

  state_set STEP_SUBSCRIPTION done
  state_set R_SUBSCRIPTION "$user:$pass"
  printf "\n${G}订阅入口${N}\n"
  printf "  公网 HTTPS : https://%s:%s@%s/%s/\n" "$user" "$pass" "$domain" "$subdir"
  [ -n "$tsip" ] && printf "  内网入口   : http://%s:%s@%s:8080/%s/\n" "$user" "$pass" "$tsip" "$subdir"
  printf "  失败时用   : %s → 内网入口（公网 TCP 可能被封）\n\n" "$(state_get R_NETWORK)"
}

# ══════════════════════════════════════════════════════════════════════
# harden —— 防火墙 + SSH
# ══════════════════════════════════════════════════════════════════════
cmd_harden() {
  asroot

  # ---------- 1. SSH：先验证密钥，再禁密码 ----------
  say "检查 authorized_keys"
  if [ ! -s /root/.ssh/authorized_keys ]; then
    die "root 没有 authorized_keys，禁止密码会导致你失联。
  先部署公钥：ssh-copy-id 或把 id_ed25519.pub 追加到 /root/.ssh/authorized_keys"
  fi
  chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys
  ok "公钥存在（$(wc -l < /root/.ssh/authorized_keys) 条）"

  backup /etc/ssh/sshd_config >/dev/null
  mkdir -p /etc/ssh/sshd_config.d
  local ovr=/etc/ssh/sshd_config.d/99-vbs-hardening.conf
  backup "$ovr" >/dev/null || true
  cat > "$ovr" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
  # 覆盖 50-cloud-init.conf 里的 PasswordAuthentication yes
  local ci=/etc/ssh/sshd_config.d/50-cloud-init.conf
  if [ -f "$ci" ]; then
    backup "$ci" >/dev/null
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$ci"
  fi
  sshd -t || die "sshd 配置语法错误，已中止（备份在 $BACKUPS）"
  systemctl restart ssh.socket 2>/dev/null || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  sleep 1
  sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|permitrootlogin|maxauthtries)' | while read -r l; do ok "$l"; done

  # ---------- 2. fail2ban ----------
  if ! has fail2ban-client; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y fail2ban 2>&1 | tail -2
  fi
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = iptables-multiport
backend = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 3
bantime  = 24h
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1
  sleep 2
  fail2ban-client status sshd >/dev/null 2>&1 && ok "fail2ban sshd jail 已启动" || warn "fail2ban 未就绪"

  # ---------- 3. iptables ----------
  say "收集业务端口"
  local TCP_PORTS="22 80 443"
  local UDP_PORTS=""
  if [ -f /etc/s-box/sb.json ] && has python3; then
    while read -r row; do
      local t p
      t=$(echo "$row" | cut -d' ' -f1); p=$(echo "$row" | cut -d' ' -f2)
      case "$t" in
        vless|vmess|anytls) TCP_PORTS="$TCP_PORTS $p" ;;
        hysteria2|tuic)     UDP_PORTS="$UDP_PORTS $p" ;;
      esac
    done < <(python3 -c "
import json
d=json.load(open('/etc/s-box/sb.json'))
for i in d['inbounds']:
    if i.get('listen_port'): print(i['type'], i['listen_port'])
" 2>/dev/null)
  fi
  # Tailscale 直连端口
  has tailscale && UDP_PORTS="$UDP_PORTS 41641"
  # 端口跳跃段
  local hop; hop=$(state_get R_HOPPING)
  local hoprange=""
  [ -n "$hop" ] && hoprange=$(echo "$hop" | grep -oE '[0-9]+:[0-9]+')
  TCP_PORTS=$(echo $TCP_PORTS | tr ' ' '\n' | sort -nu | tr '\n' ' ')
  UDP_PORTS=$(echo $UDP_PORTS | tr ' ' '\n' | sort -nu | tr '\n' ' ')

  printf "  TCP: %s\n  UDP: %s\n  UDP段: %s\n" "$TCP_PORTS" "${UDP_PORTS:-无}" "${hoprange:-无}"

  backup_iptables() {
    iptables-save  > "$BACKUPS/iptables.v4.${TS}"
    ip6tables-save > "$BACKUPS/iptables.v6.${TS}"
  }
  backup_iptables
  ok "iptables 已备份到 $BACKUPS"

  for fam in iptables ip6tables; do
    $fam -F INPUT 2>/dev/null
    $fam -F FORWARD 2>/dev/null
    $fam -A INPUT -i lo -j ACCEPT
    $fam -A INPUT -i tailscale0 -j ACCEPT          # 保命：绝不能少
    $fam -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    if [ "$fam" = "iptables" ]; then
      $fam -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    else
      $fam -A INPUT -p ipv6-icmp -j ACCEPT
    fi
    for p in $TCP_PORTS; do $fam -A INPUT -p tcp --dport "$p" -j ACCEPT; done
    for p in $UDP_PORTS; do $fam -A INPUT -p udp --dport "$p" -j ACCEPT; done
    [ -n "$hoprange" ] && $fam -A INPUT -p udp --dport "$hoprange" -j ACCEPT
    $fam -A INPUT -j DROP
    $fam -A FORWARD -j DROP
  done

  if has netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 && ok "iptables 已持久化"
  else
    warn "未安装 iptables-persistent，重启后规则会丢失：apt install iptables-persistent"
  fi

  systemctl restart fail2ban >/dev/null 2>&1

  state_set STEP_HARDEN done
  ok "加固完成"

  printf "\n${Y}立刻验证（关键）：${N}\n"
  printf "  · 新开一个终端 ssh root@%s\n" "$(state_get R_TAILSCALE)"
  printf "  · 密码登录应被拒绝：Permission denied (publickey)\n"
}

# ══════════════════════════════════════════════════════════════════════
# all —— 按序执行
# ══════════════════════════════════════════════════════════════════════
cmd_all() {
  local order="network tailscale singbox cert hopping argo subscription harden"
  for s in $order; do
    local st; st=$(state_get "STEP_$(echo "$s" | tr '[:lower:]' '[:upper:]')")
    if [ "$st" = "done" ]; then
      ok "$s 已完成，跳过"
      continue
    fi
    printf "\n${B}▶ %s${N}\n" "$s"
    CMD=$s
    "cmd_$s" || { err "$s 失败，修复后重跑： bash $0 $s"; return 1; }
  done
  cmd_status
}

# ══════════════════════════════════════════════════════════════════════
# reset
# ══════════════════════════════════════════════════════════════════════
cmd_reset() {
  local step=${1:-}
  if [ -z "$step" ]; then
    : > "$STATE"; ok "已清空所有步骤状态"
  else
    grep -v "^STEP_$(echo "$step" | tr '[:lower:]' '[:upper:]')=" "$STATE" > "$STATE.tmp" || true
    mv "$STATE.tmp" "$STATE"
    ok "已重置 $step"
  fi
}

# ══════════════════════════════════════════════════════════════════════
CMD="${1:-help}"; shift 2>/dev/null || true
case "$CMD" in
  probe)        cmd_probe "${1:-}" ;;
  status)       cmd_status ;;
  network)      cmd_network ;;
  tailscale)    CMD=tailscale cmd_tailscale ;;
  singbox)      CMD=singbox cmd_singbox ;;
  cert)         CMD=cert cmd_cert ;;
  hopping)      CMD=hopping cmd_hopping ;;
  argo)         CMD=argo cmd_argo ;;
  subscription) CMD=subscription cmd_subscription ;;
  harden)       cmd_harden ;;
  all)          cmd_all ;;
  reset)        cmd_reset "${1:-}" ;;
  help|*)
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
