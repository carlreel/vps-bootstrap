#!/usr/bin/env bash
# ============================================================
# vps-probe.sh v2 —— VPS 只读状态探针
#
# 用途：一条命令把所有关键状态摊开，AI 读它即可定位问题，
#       用户看它就知道"现在走到哪一步了"。
#
# 特性：纯只读；位置无关；缺工具自动跳过；不误报。
# 用法：bash vps-probe.sh          人类可读（tty 下带颜色）
#       bash vps-probe.sh --json   机器可读
# ============================================================

set -uo pipefail
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

has() { command -v "$1" >/dev/null 2>&1; }

if [ "$JSON" = "0" ] && [ -t 1 ]; then
  R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; N='\033[0m'; D='\033[2m'
else
  R=''; G=''; Y=''; B=''; N=''; D=''
fi

ISSUES=()
issue() { ISSUES+=("$1"); }

hdr() { [ "$JSON" = "0" ] && printf "\n${B}── %s ──${N}\n" "$1"; }
ok()  { [ "$JSON" = "0" ] && printf "  ${G}✓${N} %-22s %s\n" "$1" "${2:-}"; }
bad() { [ "$JSON" = "0" ] && printf "  ${R}✗${N} %-22s %s\n" "$1" "${2:-}"; }
inf() { [ "$JSON" = "0" ] && printf "  ${D}·${N} %-22s %s\n" "$1" "${2:-}"; }

# ---------- 基础 ----------
HOST=$(hostname 2>/dev/null || echo unknown)
OS=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)
KERNEL=$(uname -r)
NOW=$(date -Is)

V4=$(timeout 8 curl -s -4 https://ifconfig.co 2>/dev/null || true)
V6=$(timeout 8 curl -s -6 https://ifconfig.co 2>/dev/null || true)
GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')

# ---------- 服务 ----------
svc_state() { systemctl is-active "$1" 2>/dev/null || echo "absent"; }
S_SINGBOX=$(svc_state sing-box)
S_NGINX=$(svc_state nginx)
S_CFD=$(svc_state cloudflared)
S_TS=$(svc_state tailscaled)
S_F2B=$(svc_state fail2ban)

# ---------- 端口 ----------
TCP_PORTS=$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -nu | tr '\n' ' ' | sed 's/ $//')
UDP_PORTS=$(ss -lnuH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -nu | tr '\n' ' ' | sed 's/ $//')

# ---------- 防火墙（用 -S，能看见接口名和 target 原文）----------
FW_RULES=$(iptables -S INPUT 2>/dev/null || true)
FW_POLICY=$(iptables -S 2>/dev/null | awk '/^-P INPUT/{print $3; exit}')
FW_HAS_DROP=$(printf '%s\n' "$FW_RULES" | grep -c '^-A INPUT -j DROP' || true)
FW_TS_ACCEPT=$(printf '%s\n' "$FW_RULES" | grep -c '^-A INPUT -i tailscale0 -j ACCEPT' || true)
FW_TCP_ALL=$(printf '%s\n' "$FW_RULES" | grep -F -- '-p tcp' | grep -oE '\-\-dport [0-9]+' | awk '{print $2}' | sort -nu | tr '\n' ' ' | sed 's/ $//')
FW_UDP_ALL=$(printf '%s\n' "$FW_RULES" | grep -F -- '-p udp' | grep -oE '\-\-dport [0-9:]+' | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')
NAT_DNAT=$(iptables -t nat -S PREROUTING 2>/dev/null | grep DNAT | head -1 | sed 's/^-A PREROUTING //')

# ---------- 证书 ----------
CERT="/etc/s-box/cert.pem"
CERT_CN=""; CERT_EXP=""; CERT_DAYS=""
if [ -f "$CERT" ] && has openssl; then
  CERT_CN=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
  CERT_EXP=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
  END=$(date -d "$CERT_EXP" +%s 2>/dev/null || true)
  [ -n "${END:-}" ] && CERT_DAYS=$(( (END - $(date +%s)) / 86400 ))
fi
ACME_NEXT=""
for c in /root/.acme.sh/*/*.conf; do
  [ -f "$c" ] || continue
  v=$(grep -oP "(?<=Le_NextRenewTimeStr=')[^']+" "$c" 2>/dev/null || true)
  [ -n "${v:-}" ] && ACME_NEXT="$v"
done

# ---------- 隧道回源 ----------
CFD_ORIGIN=""
if [ "$S_CFD" = "active" ] && has journalctl; then
  CFD_ORIGIN=$(journalctl -u cloudflared --no-pager --since "48 hours ago" 2>/dev/null \
    | grep -oE 'originService=[a-z]+://[^ ]+' | tail -1 | sed 's/originService=//')
  if [ -z "$CFD_ORIGIN" ]; then
    CFD_ORIGIN=$(journalctl -u cloudflared --no-pager --since "48 hours ago" 2>/dev/null \
      | grep -oE 'hostname[^,]{0,60}service[^,]{0,60}' | tail -1)
  fi
fi

# ---------- 订阅 ----------
SUB_UUID=$([ -f /etc/s-box/subtoken.log ] && tr -d '\r\n' < /etc/s-box/subtoken.log || true)
SUB_NODES=$(grep -c '://' /etc/s-box/jhsub.txt 2>/dev/null || true)
CLASH_OK="n/a"
if [ -f /etc/s-box/clmi.yaml ] && has python3; then
  if python3 -c "import yaml;yaml.safe_load(open('/etc/s-box/clmi.yaml',encoding='utf-8'))" 2>/dev/null; then CLASH_OK="ok"; else CLASH_OK="parse-error"; fi
fi

# ============================================================
if [ "$JSON" = "1" ]; then
cat <<EOF
{
  "ts": "$NOW", "host": "$HOST", "os": "$OS", "kernel": "$KERNEL",
  "public_v4": "${V4:-}", "public_v6": "${V6:-}", "gateway": "${GW:-}",
  "services": {"sing-box":"$S_SINGBOX","nginx":"$S_NGINX","cloudflared":"$S_CFD","tailscaled":"$S_TS","fail2ban":"$S_F2B"},
  "listen": {"tcp":"$TCP_PORTS","udp":"$UDP_PORTS"},
  "firewall": {"policy":"${FW_POLICY:-unknown}","has_drop_rule":${FW_HAS_DROP:-0},"tailscale_iface_accept":${FW_TS_ACCEPT:-0},"tcp_open":"$FW_TCP_ALL","udp_open":"$FW_UDP_ALL","nat_dnat":"$NAT_DNAT"},
  "cert": {"cn":"$CERT_CN","not_after":"$CERT_EXP","days_left":"${CERT_DAYS:-}","acme_next_renew":"$ACME_NEXT"},
  "tunnel": {"origin":"$CFD_ORIGIN"},
  "subscription": {"uuid":"${SUB_UUID:-}","node_count":${SUB_NODES:-0},"clash_yaml":"$CLASH_OK"}
}
EOF
exit 0
fi

# ============================================================
printf "${B}════════ VPS PROBE v2 ════════${N}\n"
printf "  %s\n  %s / %s / kernel %s\n" "$NOW" "$HOST" "$OS" "$KERNEL"
printf "  v4: %s   v6: %s   gw: %s\n" "${V4:-none}" "${V6:-none}" "${GW:-none}"

hdr "1. 服务"
for pair in "sing-box:$S_SINGBOX" "nginx:$S_NGINX" "cloudflared:$S_CFD" "tailscaled:$S_TS" "fail2ban:$S_F2B"; do
  n=${pair%%:*}; s=${pair#*:}
  case "$s" in
    active) ok "$n" "$s" ;;
    absent) inf "$n" "(未安装)" ;;
    *) bad "$n" "$s"; issue "$n 状态=$s" ;;
  esac
done

hdr "2. 端口"
inf "TCP 监听" "${TCP_PORTS:-none}"
inf "UDP 监听" "${UDP_PORTS:-none}"
[ -z "$TCP_PORTS" ] && issue "没有任何 TCP 监听"

hdr "3. 防火墙"
if [ "${FW_HAS_DROP:-0}" -gt 0 ]; then
  ok "模式" "白名单 + DROP（已加固）"
else
  inf "模式" "policy=${FW_POLICY:-?}，无 DROP 兜底（未加固）"
fi
if [ "${FW_TS_ACCEPT:-0}" -gt 0 ]; then
  ok "tailscale0" "已放行"
else
  bad "tailscale0" "未放行 → Tailscale 会被自身防火墙切断"
  issue "iptables INPUT 未放行 tailscale0（会切断 Tailscale 保命通道）"
fi
inf "TCP 放行" "${FW_TCP_ALL:-none}"
inf "UDP 放行" "${FW_UDP_ALL:-none}"
[ -n "$NAT_DNAT" ] && inf "NAT DNAT" "$(printf '%s' "$NAT_DNAT" | tr '|' ' ' | cut -c1-95)"

hdr "4. 证书"
if [ -n "$CERT_CN" ]; then
  inf "CN" "$CERT_CN"
  inf "到期" "$CERT_EXP"
  if [ -n "${CERT_DAYS:-}" ] && [ "$CERT_DAYS" -lt 15 ] 2>/dev/null; then
    bad "剩余" "${CERT_DAYS} 天 —— 续期可能失效"; issue "证书仅剩 ${CERT_DAYS} 天"
  else
    ok "剩余" "${CERT_DAYS:-?} 天"
  fi
  [ -n "$ACME_NEXT" ] && inf "下次续期" "$ACME_NEXT"
else
  bad "证书" "未找到 $CERT"; issue "未找到站点证书 $CERT"
fi

hdr "5. Cloudflare 隧道"
if [ "$S_CFD" = "active" ]; then
  inf "回源" "${CFD_ORIGIN:-未取到（可能近期无请求）}"
  case "$CFD_ORIGIN" in
    https://localhost*) bad "协议" "origin 是 HTTPS，若后端为明文会握手失败"; issue "tunnel origin 用了 https，应确认后端是否启用了 TLS" ;;
    http://localhost*)  ok "协议" "http（正确）" ;;
  esac
else
  inf "cloudflared" "未运行（不需要 Argo 可忽略）"
fi

hdr "6. 订阅"
if [ -n "${SUB_UUID:-}" ]; then
  ok "UUID" "$SUB_UUID"
  inf "节点数" "${SUB_NODES:-0}"
  case "$CLASH_OK" in
    ok) ok "clmi.yaml" "YAML 通过" ;;
    parse-error) bad "clmi.yaml" "YAML 解析失败"; issue "clmi.yaml 语法错误" ;;
    *) inf "clmi.yaml" "$CLASH_OK" ;;
  esac
else
  inf "订阅" "未配置"
fi

hdr "7. 异常汇总"
if [ ${#ISSUES[@]} -eq 0 ]; then
  printf "  ${G}未发现明显异常${N}\n"
else
  for i in "${ISSUES[@]}"; do printf "  ${R}!${N} %s\n" "$i"; done
fi
printf "\n"
