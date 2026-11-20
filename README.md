# vps-bootstrap

VPS 自建代理的**编排器 + AI 操作手册**。目标：替代 / 超越 `sing-box-yg (sb)` 脚本，覆盖「从一台空服务器到订阅可用」的全流程，并规避 9 个已知的坑。

## 它解决什么问题

sb 脚本能一键装起 sing-box，但它在这些地方会坑人：

- 装完不知道**网络层到底通不通**（TCP 全封 vs 端口封 vs UDP 可用）
- 证书"看起来申请成功"，但客户端里的 SNI 全部失配，TLS 节点全挂
- 端口跳跃和已有服务撞端口，静默失效
- Cloudflare Tunnel 的 ingress 协议配错，隧道 HEALTHY 但访问 502
- 防火墙把 Tailscale 自己的通道切了，从此失联
- 跨会话没有进度记忆，新对话要从头问一遍

本项目用**三层结构**解决：

| 层 | 载体 | 作用 |
|---|---|---|
| **状态层** | `/root/.vps-bootstrap/state.env` | 持久化进度，跨会话不丢 |
| **执行层** | `vps-bootstrap.sh <cmd>` | 幂等分步操作，每步自校验 |
| **判断层** | `SKILL.md` | 决策树、失败分支、禁止事项（**给 AI 读**） |

## 快速开始

```bash
# 1. 送进服务器（仓库为 public，直接拉）
curl -fsSL https://raw.githubusercontent.com/carlreel/vps-bootstrap/main/vps-bootstrap.sh -o /root/vps-bootstrap.sh
chmod +x /root/vps-bootstrap.sh

# 2. 看现状 / 看进度
bash /root/vps-bootstrap.sh probe          # 人读
bash /root/vps-bootstrap.sh probe --json   # 贴给 AI
bash /root/vps-bootstrap.sh status         # 做到第几步

# 3. 逐步执行（每步可单独跑、可重跑）
bash /root/vps-bootstrap.sh network
bash /root/vps-bootstrap.sh tailscale key=tskey-auth-xxxxx
bash /root/vps-bootstrap.sh singbox
bash /root/vps-bootstrap.sh cert domain=sub.example.com
bash /root/vps-bootstrap.sh hopping range=30000:35000
bash /root/vps-bootstrap.sh argo token=eyJh...
bash /root/vps-bootstrap.sh subscription
bash /root/vps-bootstrap.sh harden

# 或按序跑完剩余步骤
bash /root/vps-bootstrap.sh all
```

## 文件说明

| 文件 | 给谁 | 说明 |
|---|---|---|
| **`SKILL.md`** | **只给 AI 读** | 阶段零诊断、决策树、8 步流程、9 条禁止事项、失败排查表 |
| `PLAYBOOK.md` | 人 + AI | 三条路线、8 个真实踩坑、协议可用性速查、环境清单模板 |
| `vps-bootstrap.sh` | 执行 | 编排器：8 步子命令 + 状态机 + 端口冲突预检 |
| `vps-probe.sh` | 双方 | 独立只读探针（更详细），`--json` 可贴给 AI |

## 相对 sb 的改进

| 维度 | sb | 本项目 |
|---|---|---|
| 跨会话进度 | 无 | `state.env` 持久化，跨会话可续 |
| 每步验证 | 装完就算完 | 每步 post-check，不过就停 |
| 端口冲突 | 会撞 | `hopping` / `harden` 前先扫 `ss` 预检 |
| 证书分发 | 只认 `ca.log`，其余不管 | 自动修 `sni` / `pinSHA256` / `skip-cert-verify` |
| 失败处理 | 重装 | 单步重跑 + 每次改动前时间戳备份 |
| AI 可读 | 否 | `probe --json` |
| 手工介入点 | 埋在交互菜单里 | `SKILL.md` 第 4 节显式列出 |

## 必须人工完成的事

这五件事 AI 做不到，脚本会明确提示：

1. **首次 SSH 不通时**的 CloudCone/服务商面板 VNC
2. **跑 sb 的交互式安装**（纯 TTY 菜单）
3. **Cloudflare 后台配 ingress**：`Service = HTTP` / `URL = localhost:2082`
   （填成 HTTPS 会让 cloudflared 对明文后端做 TLS 握手 → `tls: first record does not look like a TLS handshake` → 502）
4. **客户端里填账号密码 / 私钥**
5. **从客户端测封锁模式**（用 `check-host.net`）

## 前提条件

- Ubuntu 22.04 / 24.04（Debian 系）
- root 权限
- **已安装 `sing-box-yg`**：`cert` 与 `hopping` 会读取 `/etc/s-box/sb.json`
- Cloudflare 账号（可选，仅 Argo 需要）
- 一个已解析到本机的域名（可选，仅域名证书需要）

## 状态文件位置

```
/root/.vps-bootstrap/state.env    # 进度（KEY=VALUE，可直接 cat）
/root/.vps-bootstrap/logs/        # 各步日志
/root/.vps-bootstrap/backups/     # 改动前备份（按时间戳命名）
```

## 设计取舍

**为什么不是纯 skill 文本**：跨会话会丢进度，每次都要重新探一遍。
**为什么不是纯菜单脚本**：判断逻辑写不进菜单，「TCP 全封 → 该走 UDP」这类推理必须由 AI 完成。
**为什么是这三层**：状态给记忆，脚本给执行，手册给判断——缺一层就会退回 sb 的水平。

---

适用场景：自有 VPS 的日常运维与迁移。
