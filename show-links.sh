#!/usr/bin/env bash
# ============================================================================
# show-links.sh — 一行命令列出本机全部订阅链接与 SSH 入口
#
# 为什么需要它：
#   订阅链接很长（域名 + 40 位 UUID + 账号密码），手抄必错；
#   而且有两个入口（公网 443 / Tailscale 8080），到底该复制哪一条很容易搞混。
#   跑这个脚本，屏幕上就是能直接复制的成串地址，还会标出哪条当前可用。
#
# 用法：
#   bash show-links.sh             人读格式（默认，带可用性检测）
#   bash show-links.sh --bare      只输出 URL，一行一条（给脚本用）
#   bash show-links.sh --json      机器可读 JSON
#   bash show-links.sh --no-check  跳过可用性检测（快 1~2 秒）
#
# 依赖：curl。所有值都从 state.env 读，不硬编码任何 IP / UUID / 密码。
# ============================================================================
set -uo pipefail

STATE_FILE="${STATE_FILE:-/root/.vps-bootstrap/state.env}"
WEBBOX_DIR="${WEBBOX_DIR:-/root/websbox}"
SUB_TOKEN_LOG="${SUB_TOKEN_LOG:-/etc/s-box/subtoken.log}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/sub}"
CURL_MAX="${CURL_MAX:-8}"

MODE=pretty
CHECK=1
for a in "$@"; do
  case "$a" in
    --bare|--urls) MODE=bare ;;
    --json)        MODE=json ;;
    --no-check)    CHECK=0 ;;
    -h|--help)     sed -n '1,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知参数：%s\n' "$a" >&2; exit 2 ;;
  esac
done

# ── 颜色（非交互输出自动关闭） ───────────────────────────────────────────
if [ "$MODE" = pretty ] && [ -t 1 ]; then
  G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; D='\033[2m'; B='\033[1m'; N='\033[0m'
else
  G=''; Y=''; R=''; C=''; D=''; B=''; N=''
fi

# ── 读取状态 ─────────────────────────────────────────────────────────────
R_NETWORK=""; R_TAILSCALE=""; R_CERT=""; R_SUBSCRIPTION=""; R_SUB_UUID=""
R_ARGO_DOMAIN=""; R_HOPPING=""
if [ -f "$STATE_FILE" ]; then
  # 只取 R_* 赋值行，避免执行文件里的其它内容
  while IFS= read -r __ln; do
    case "$__ln" in
      R_*=*) eval "$__ln" 2>/dev/null || true ;;
    esac
  done < "$STATE_FILE"
fi

# 认证信息：优先 state.env，其次 /root/sub-auth.txt
if [ -z "${R_SUBSCRIPTION:-}" ] && [ -f /root/sub-auth.txt ]; then
  R_SUBSCRIPTION=$(cat /root/sub-auth.txt 2>/dev/null | tr -d '\r\n')
fi
SUB_USER="${R_SUBSCRIPTION%%:*}"
SUB_PASS="${R_SUBSCRIPTION#*:}"

# UUID：state.env → websbox 目录名 → subtoken.log → nginx root
UUID="${R_SUB_UUID:-}"
if [ -z "$UUID" ] && [ -d "$WEBBOX_DIR" ]; then
  UUID=$(find "$WEBBOX_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
          | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' | head -1)
fi
if [ -z "$UUID" ] && [ -f "$SUB_TOKEN_LOG" ]; then
  UUID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$SUB_TOKEN_LOG" 2>/dev/null | head -1)
fi

# 顺手回填缺失的 UUID（下次就不必再找）
if [ -n "$UUID" ] && [ -z "${R_SUB_UUID:-}" ] && [ -w "$STATE_FILE" -o -w "$(dirname "$STATE_FILE")" ]; then
  printf 'R_SUB_UUID=%s\n' "$UUID" >> "$STATE_FILE" 2>/dev/null || true
fi

# ── 缺少关键信息时给出明确指引，而不是输出半截链接 ───────────────────────
missing=()
if [ -z "$SUB_USER" ] || [ -z "$SUB_PASS" ] || [ "$SUB_USER" = "$SUB_PASS" ]; then
  missing+=("订阅账号密码（R_SUBSCRIPTION 或 /root/sub-auth.txt）")
fi
[ -z "$UUID" ] && missing+=("订阅 UUID（R_SUB_UUID 或 $SUB_TOKEN_LOG）")
[ -z "${R_CERT:-}${R_TAILSCALE:-}" ] && missing+=("至少一个入口地址（R_CERT 域名 或 R_TAILSCALE IP）")
if [ ${#missing[@]} -gt 0 ]; then
  printf '✗ 信息不全，无法拼出链接：\n' >&2
  for m in "${missing[@]}"; do printf '  · %s\n' "$m" >&2; done
  printf '\n先跑一次 `bash vps-bootstrap.sh subscription` 或手工补齐 %s\n' "$STATE_FILE" >&2
  exit 1
fi

# ── 探测某个 URL 是否 200 ────────────────────────────────────────────────
probe_code() {
  local url=$1 host=$2 port=$3
  if [ "$CHECK" = 0 ]; then printf 'skip'; return; fi
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX" \
            --resolve "${host}:${port}:127.0.0.1" -u "${SUB_USER}:${SUB_PASS}" "$url" 2>/dev/null)
  # Tailscale 监听不能靠 --resolve 回环命中，直接打内网 IP
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX" \
              -u "${SUB_USER}:${SUB_PASS}" "$url" 2>/dev/null)
  fi
  printf '%s' "${code:-000}"
}

# ── 收集条目 ─────────────────────────────────────────────────────────────
# 每个文件给出人话说明，客户端认哪种格式一眼可见
file_label() {
  case "$1" in
    clmi.yaml|*.yaml|*.yml) printf 'Clash / mihomo / Clash Verge / FlClash' ;;
    jhsub.txt)              printf 'v2rayN / Karing / Shadowrocket / NekoBox' ;;
    jhsub-lite.txt)         printf '同上，去 port-hopping 的兼容版（老客户端用）' ;;
    sbox.json|*.json)       printf 'sing-box 原生（SFA / SFI / Karing 内核）' ;;
    *.txt)                  printf '通用 TXT 订阅' ;;
    *)                      printf '%s' "$(printf '%s' "$1" | sed 's/.*\.//')" ;;
  esac
}

FILES=()
if [ -n "${UUID:-}" ] && [ -d "$WEBBOX_DIR/$UUID" ]; then
  while IFS= read -r f; do
    [ -e "$f" ] || continue            # 断链跳过
    FILES+=("$(basename "$f")")
  done < <(find "$WEBBOX_DIR/$UUID" -maxdepth 1 -mindepth 1 \( -name '*.yaml' -o -name '*.yml' -o -name '*.txt' -o -name '*.json' \) | sort)
fi

# 按「新手最该先粘哪个」排序：Clash 系 → TXT → 兼容 TXT → sing-box JSON
if [ ${#FILES[@]} -gt 1 ]; then
  __ordered=()
  for __want in clmi.yaml jhsub.txt jhsub-lite.txt sbox.json; do
    for __f in "${FILES[@]}"; do
      [ "$__f" = "$__want" ] && __ordered+=("$__f")
    done
  done
  for __f in "${FILES[@]}"; do
    __hit=0
    if [ ${#__ordered[@]} -gt 0 ]; then
      for __o in "${__ordered[@]}"; do
        [ "$__f" = "$__o" ] && { __hit=1; break; }
      done
    fi
    [ "$__hit" = 0 ] && __ordered+=("$__f")
  done
  FILES=("${__ordered[@]}")
fi

# 入口表：label|base_url|host|port
ENTRIES=()
[ -n "${R_CERT:-}" ] && ENTRIES+=("公网 443（走 TCP，运营商可能封 IP）|https://${R_CERT}|${R_CERT}|443")
[ -n "${R_TAILSCALE:-}" ] && ENTRIES+=("Tailscale 8080（内网，需本机装 Tailscale 并登录）|http://${R_TAILSCALE}:8080|${R_TAILSCALE}|8080")

# ── JSON 模式 ────────────────────────────────────────────────────────────
if [ "$MODE" = json ]; then
  printf '{\n  "generated": "%s",\n  "uuid": "%s",\n  "auth_user": "%s",\n  "entries": [\n' \
         "$(date -Iseconds)" "$UUID" "$SUB_USER"
  first=1
  for e in "${ENTRIES[@]}"; do
    IFS='|' read -r lbl base host port <<< "$e"
    [ $first -eq 0 ] && printf ',\n'; first=0
    code=$(probe_code "${base}/${UUID}/clmi.yaml" "$host" "$port")
    printf '    {"label": "%s", "base": "%s", "ok": %s, "links": [' "$lbl" "$base" \
           "$([ "$code" = 200 ] && printf true || printf false)"
    f1=1
    for f in "${FILES[@]}"; do
      [ $f1 -eq 0 ] && printf ', '; f1=0
      printf '{"file": "%s", "url": "%s/%s/%s"}' "$f" "${base%%://*}://${SUB_USER}:${SUB_PASS}@${base#*://}" "$UUID" "$f"
    done
    printf ']}'
  done
  printf '\n  ]\n}\n'
  exit 0
fi

# ── --bare 模式 ──────────────────────────────────────────────────────────
if [ "$MODE" = bare ]; then
  for e in "${ENTRIES[@]}"; do
    IFS='|' read -r lbl base host port <<< "$e"
    for f in "${FILES[@]}"; do
      printf '%s/%s/%s\n' "${base%%://*}://${SUB_USER}:${SUB_PASS}@${base#*://}" "$UUID" "$f"
    done
  done
  exit 0
fi

# ── 人读模式 ─────────────────────────────────────────────────────────────
line() { printf '%s\n' "────────────────────────────────────────────────────────────────────────"; }
big()  { printf '%s\n' "════════════════════════════════════════════════════════════════════════"; }

big
printf '  %s订阅链接一览%s    %s\n' "$B" "$N" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
big
printf '  UUID: %s\n' "$UUID"
printf '  账号: %s    密码: %s   %s（链接里已内嵌，复制即可用）%s\n' "$SUB_USER" "$SUB_PASS" "$D" "$N"
line

for e in "${ENTRIES[@]}"; do
  IFS='|' read -r lbl base host port <<< "$e"
  code=$(probe_code "${base}/${UUID}/clmi.yaml" "$host" "$port")
  case "$code" in
    200)      badge="${G}● 本机可用${N}" ;;
    skip)     badge="${D}● 未检测${N}" ;;
    000|"")   badge="${R}● 连不上${N}" ;;
    401)      badge="${Y}● 401 账号密码不对${N}" ;;
    *)        badge="${Y}● HTTP $code${N}" ;;
  esac
  printf '  %s%s%s  %s\n' "$B" "$lbl" "$N" "$badge"
  authbase="${base%%://*}://${SUB_USER}:${SUB_PASS}@${base#*://}"
  for f in "${FILES[@]}"; do
    printf '    %-16s %s\n' "$f" "$(file_label "$f")"
    printf '    %s%s/%s/%s%s\n' "$C" "$authbase" "$UUID" "$f" "$N"
  done
  printf '\n'
done

line
printf '  %sSSH 管理入口%s\n' "$B" "$N"
[ -n "${R_TAILSCALE:-}" ] && printf '    ssh root@%s    %s（Tailscale，需本机在线，最稳）%s\n' "$R_TAILSCALE" "$D" "$N"
[ -n "${R_NETWORK:-}" ]   && printf '    ssh root@%s      %s（公网直连，国内多数情况会被丢包）%s\n' "$R_NETWORK" "$D" "$N"
printf '    别名：ssh server1 / ssh s1\n\n'

line
printf '  %s怎么选%s\n' "$B" "$N"
printf '    · 两个入口内容完全一样，任选其一即可，不必都填\n'
printf '    · 拉不到 / 很慢时，换另一个入口试试（这是保留两个的唯一理由）\n'
printf '    · Tailscale 入口要求本机装了 Tailscale 且已登录；卸载/退出后该链接失效\n'
printf '    · 公网入口要求运营商没封这个 IP 的 TCP 443（2026-11-20 曾被整 IP 丢弃过）\n'
printf '    · Clash 系客户端粘 clmi.yaml；v2rayN / Karing 粘 jhsub.txt；老客户端用 jhsub-lite.txt\n'
big
[ "$CHECK" = 1 ] && printf '  检测为服务器本机自测（127.0.0.1），只证明 nginx 与证书正常；\n  客户端能否拉到还取决于你所在网络的封锁情况。\n'
