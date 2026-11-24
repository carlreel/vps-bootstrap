#!/usr/bin/env bash
# ============================================================================
# show-links.sh — 列出本机全部订阅链接（公网 + Tailscale），可直接复制粘贴
#
# 设计约束（都是踩出来的）：
#   · 中文在终端里占 2 列，所以**不对含中文的行做 %-Ns 补空格**，否则整列错位
#   · 每条 URL 独立成行、前面只有 2 格缩进，鼠标三击就能选中整行
#   · 横线宽度跟随终端宽度（上限 78），窗口窄了也不会折行
#   · 徽标只用 ASCII（[OK] / [FAIL]），不用 ● ✓ 这类可能缺字形的符号
#
# 用法：
#   bash show-links.sh            人读格式（带可用性检测）
#   bash show-links.sh --bare     只有 URL，一行一条（拖选全部即全部链接）
#   bash show-links.sh --save     写到 /root/subscription-links.txt 并打印路径
#   bash show-links.sh --json     JSON（给脚本用）
#   bash show-links.sh --no-check 跳过可用性检测
# ============================================================================
set -uo pipefail

STATE_FILE="${STATE_FILE:-/root/.vps-bootstrap/state.env}"
WEBBOX_DIR="${WEBBOX_DIR:-/root/websbox}"
SUB_TOKEN_LOG="${SUB_TOKEN_LOG:-/etc/s-box/subtoken.log}"
SAVE_PATH="${SAVE_PATH:-/root/subscription-links.txt}"
CURL_MAX="${CURL_MAX:-8}"

MODE=pretty
CHECK=1
for a in "$@"; do
  case "$a" in
    --bare|--urls) MODE=bare ;;
    --save)        MODE=save ;;
    --json)        MODE=json ;;
    --no-check)    CHECK=0 ;;
    -h|--help)     sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知参数：%s\n' "$a" >&2; exit 2 ;;
  esac
done

# ── 终端宽度（跟随窗口，上限 78，下限 46） ───────────────────────────────
# 优先看真实 tty 宽度；非 tty（比如重定向到文件）时用 COLUMNS，否则默认 78
COLS=""
if [ -t 1 ]; then
  COLS=$(tput cols 2>/dev/null || true)
fi
[ -z "$COLS" ] && COLS="${COLUMNS:-78}"
case "$COLS" in ''|*[!0-9]*) COLS=78 ;; esac
[ "$COLS" -gt 78 ] && COLS=78
[ "$COLS" -lt 46 ] && COLS=46
W=$COLS

hr()  { printf '%*s\n' "$W" '' | tr ' ' '-'; }
eq()  { printf '%*s\n' "$W" '' | tr ' ' '='; }

# ── 颜色（非 tty 关闭） ──────────────────────────────────────────────────
if [ -t 1 ] && [ "$MODE" = pretty ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; Y=''; R=''; D=''; B=''; N=''
fi

# ── 读状态 ───────────────────────────────────────────────────────────────
R_NETWORK=""; R_TAILSCALE=""; R_CERT=""; R_SUBSCRIPTION=""; R_SUB_UUID=""
if [ -f "$STATE_FILE" ]; then
  while IFS= read -r __ln; do
    case "$__ln" in
      R_*=*) eval "$__ln" 2>/dev/null || true ;;
    esac
  done < "$STATE_FILE"
fi

if [ -z "${R_SUBSCRIPTION:-}" ] && [ -f /root/sub-auth.txt ]; then
  R_SUBSCRIPTION=$(tr -d '\r\n' < /root/sub-auth.txt 2>/dev/null)
fi
SUB_USER="${R_SUBSCRIPTION%%:*}"
SUB_PASS="${R_SUBSCRIPTION#*:}"

UUID="${R_SUB_UUID:-}"
if [ -z "$UUID" ] && [ -d "$WEBBOX_DIR" ]; then
  UUID=$(find "$WEBBOX_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
          | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' | head -1)
fi
if [ -z "$UUID" ] && [ -f "$SUB_TOKEN_LOG" ]; then
  UUID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$SUB_TOKEN_LOG" 2>/dev/null | head -1)
fi
if [ -n "$UUID" ] && [ -z "${R_SUB_UUID:-}" ] && [ -w "$(dirname "$STATE_FILE")" ]; then
  printf 'R_SUB_UUID=%s\n' "$UUID" >> "$STATE_FILE" 2>/dev/null || true
fi

missing=()
if [ -z "$SUB_USER" ] || [ -z "$SUB_PASS" ] || [ "$SUB_USER" = "$SUB_PASS" ]; then
  missing+=("订阅账号密码（R_SUBSCRIPTION 或 /root/sub-auth.txt）")
fi
[ -z "$UUID" ] && missing+=("订阅 UUID（R_SUB_UUID 或 $SUB_TOKEN_LOG）")
[ -z "${R_CERT:-}${R_TAILSCALE:-}" ] && missing+=("至少一个入口地址（R_CERT 域名 或 R_TAILSCALE IP）")
if [ ${#missing[@]} -gt 0 ]; then
  printf '错误：信息不全，无法拼出链接\n' >&2
  for m in "${missing[@]}"; do printf '  - %s\n' "$m" >&2; done
  printf '\n先跑一次 bash vps-bootstrap.sh subscription，或手工补齐 %s\n' "$STATE_FILE" >&2
  exit 1
fi

# ── 探测入口是否 200 ─────────────────────────────────────────────────────
probe_code() {
  local url=$1 host=$2 port=$3 code
  if [ "$CHECK" = 0 ]; then printf 'skip'; return; fi
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX" \
            --resolve "${host}:${port}:127.0.0.1" -u "${SUB_USER}:${SUB_PASS}" "$url" 2>/dev/null)
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX" \
              -u "${SUB_USER}:${SUB_PASS}" "$url" 2>/dev/null)
  fi
  printf '%s' "${code:-000}"
}

# ── 文件清单（按「新手先粘哪个」排序） ──────────────────────────────────
FILES=()
if [ -n "${UUID:-}" ] && [ -d "$WEBBOX_DIR/$UUID" ]; then
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    FILES+=("$(basename "$f")")
  done < <(find "$WEBBOX_DIR/$UUID" -maxdepth 1 -mindepth 1 \
             \( -name '*.yaml' -o -name '*.yml' -o -name '*.txt' -o -name '*.json' \) | sort)
fi
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
      for __o in "${__ordered[@]}"; do [ "$__f" = "$__o" ] && { __hit=1; break; }; done
    fi
    [ "$__hit" = 0 ] && __ordered+=("$__f")
  done
  FILES=("${__ordered[@]}")
fi

file_desc() {
  # 窄终端用短标签，避免说明文字自己折行
  if [ "$W" -lt 62 ]; then
    case "$1" in
      clmi.yaml|*.yaml|*.yml) printf 'Clash 系' ;;
      jhsub.txt)              printf 'v2rayN 等' ;;
      jhsub-lite.txt)         printf '老客户端' ;;
      sbox.json|*.json)       printf 'sing-box' ;;
      *.txt)                  printf 'TXT' ;;
      *)                      printf '其它' ;;
    esac
    return
  fi
  case "$1" in
    clmi.yaml|*.yaml|*.yml) printf 'Clash Verge / ClashX / FlClash / mihomo' ;;
    jhsub.txt)              printf 'v2rayN / Karing / Shadowrocket / NekoBox' ;;
    jhsub-lite.txt)         printf '同上，但去掉了端口跳跃（老版本客户端）' ;;
    sbox.json|*.json)       printf 'sing-box 原生（SFA / SFI / Karing 内核）' ;;
    *.txt)                  printf '通用 TXT 订阅' ;;
    *)                      printf '其它格式' ;;
  esac
}

# ── 入口表 ───────────────────────────────────────────────────────────────
ENTRIES=()
[ -n "${R_CERT:-}" ]      && ENTRIES+=("A|公网 443|https://${R_CERT}|${R_CERT}|443")
[ -n "${R_TAILSCALE:-}" ] && ENTRIES+=("B|Tailscale 8080|http://${R_TAILSCALE}:8080|${R_TAILSCALE}|8080")

url_of() {   # url_of <base> <file>
  printf '%s://%s:%s@%s/%s/%s' "${1%%://*}" "$SUB_USER" "$SUB_PASS" "${1#*://}" "$UUID" "$2"
}

# ── JSON ─────────────────────────────────────────────────────────────────
if [ "$MODE" = json ]; then
  printf '{\n  "generated": "%s",\n  "uuid": "%s",\n  "auth_user": "%s",\n  "entries": [\n' \
         "$(date -Iseconds)" "$UUID" "$SUB_USER"
  first=1
  for e in "${ENTRIES[@]}"; do
    IFS='|' read -r key lbl base host port <<< "$e"
    [ $first -eq 0 ] && printf ',\n'; first=0
    code=$(probe_code "$base/$UUID/clmi.yaml" "$host" "$port")
    [ "$code" = 200 ] && okv=true || okv=false
    printf '    {"key": "%s", "label": "%s", "base": "%s", "ok": %s, "links": [' "$key" "$lbl" "$base" "$okv"
    f1=1
    for f in "${FILES[@]}"; do
      [ $f1 -eq 0 ] && printf ', '; f1=0
      printf '{"file": "%s", "url": "%s"}' "$f" "$(url_of "$base" "$f")"
    done
    printf ']}'
  done
  printf '\n  ]\n}\n'
  exit 0
fi

# ── --bare / --save：只有 URL ────────────────────────────────────────────
collect_urls() {
  local e base
  for e in "${ENTRIES[@]}"; do
    IFS='|' read -r _ _ base _ _ <<< "$e"
    for f in "${FILES[@]}"; do url_of "$base" "$f"; printf '\n'; done
  done
}

if [ "$MODE" = bare ]; then collect_urls; exit 0; fi

if [ "$MODE" = save ]; then
  collect_urls > "$SAVE_PATH" || { printf '写入失败：%s\n' "$SAVE_PATH" >&2; exit 1; }
  chmod 600 "$SAVE_PATH"
  n=$(wc -l < "$SAVE_PATH")
  printf '已写入 %s（%s 条链接，权限 600）\n\n' "$SAVE_PATH" "$n"
  printf '查看：  cat %s\n' "$SAVE_PATH"
  printf '下载：  Tabby / MobaXterm 的 SFTP 面板，路径填 %s\n' "$SAVE_PATH"
  exit 0
fi

# ── 人读格式 ─────────────────────────────────────────────────────────────
badge() {
  case "$1" in
    200)     printf '%s[OK]%s' "$G" "$N" ;;
    skip)    printf '%s[SKIP]%s' "$D" "$N" ;;
    000|"")  printf '%s[FAIL]%s' "$R" "$N" ;;
    401)     printf '%s[401]%s' "$Y" "$N" ;;
    *)       printf '%s[%s]%s' "$Y" "$1" "$N" ;;
  esac
}

idx=0
eq
printf ' CloudCone VPS  订阅链接一览\n'
printf ' %s   UUID %s\n' "$(date '+%Y-%m-%d %H:%M')" "$UUID"
eq
printf '\n'

for e in "${ENTRIES[@]}"; do
  IFS='|' read -r key lbl base host port <<< "$e"
  code=$(probe_code "$base/$UUID/clmi.yaml" "$host" "$port")
  printf ' %s 入口 %s · %s\n' "$(badge "$code")" "$key" "$lbl"
  hr
  for f in "${FILES[@]}"; do
    idx=$((idx+1))
    printf '  [%d] %-16s %s\n' "$idx" "$f" "$(file_desc "$f")"
    printf '  %s\n' "$(url_of "$base" "$f")"
    printf '\n'
  done
done

hr
printf ' 怎么用\n'
hr
printf '  1. 一次只填 1 条。同一入口的 4 个文件内容相同，只是格式不同。\n'
printf '  2. 链接已含账号密码，直接粘进客户端，不用另填。\n'
printf '  3. 拉不动就换另一个入口的同类文件（入口 A 挂了换 B，反之亦然）。\n'
if [ "$W" -lt 62 ]; then
  printf '  4. URL 折行只是显示，文件里只有一行，三击那一行即可整条选中。\n'
else
  printf '  4. URL 超过窗口宽度会折成两行，这是正常的 —— 它在文件里只有一行，\n'
  printf '     鼠标三击那一行即可整条选中（第二行只是显示折行，不是换行）。\n'
fi
printf '\n'
printf ' 想一次性拿到干净列表（推荐，不用手选）\n'
hr
if [ "$W" -lt 62 ]; then
  printf '  在命令后面加参数：\n'
  printf '    --bare   只吐 URL，一行一条\n'
  printf '    --save   写到 %s\n' "$SAVE_PATH"
else
  printf '  bash %s --bare    只吐 URL，一行一条\n' "$0"
  printf '  bash %s --save    写到 %s\n' "$0" "$SAVE_PATH"
fi
eq
if [ "$CHECK" = 1 ]; then
  printf ' %s注：检测是服务器本机自测（127.0.0.1），只证明 nginx 与证书正常；%s\n' "$D" "$N"
  printf ' %s    你那边能不能拉到，还取决于当地运营商的封锁。%s\n' "$D" "$N"
fi
