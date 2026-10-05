# Infra-node

Infra-node 是用于代理节点 VPS 的**主机基础设施层**。它提前完成系统评估、基础安全、保守网络调优、日志与时间同步、可选 Swap、代理 systemd 资源限制适配，以及可选 nftables 主机防火墙。

> 项目不安装代理程序，不生成代理配置、证书、密钥或订阅，不修改 SSH 用户/密钥/认证方式，也不运行常驻测速、监控或自动更新代理任务。

## v1.6.3 修复重点

- **`--dry-run` 现在真的只预演。** 此前它仍会写入 sysctl、journald 和代理 drop-in，
  创建固定目录，并在小内存主机上创建 Swap 与写 `/etc/fstab`；现在所有写入路径都已拦截。
- **代理 systemd 资源限制此前从未生效**：drop-in 被写到 `<unit>.service.d/`，
  systemd 永不读取。现修正为 `<unit>.d/`。
- **内核缺少 IPv6 开关（`ipv6.disable=1`）时不再中止整个部署**，
  改为按内核实际支持的开关过滤并提示被跳过的项。
- **`backup restore` 增加固定路径白名单**，越界事务会在删除任何文件前整批中止。
- **防火墙确认后不再被失败钩子撤销**；Swap 与 `/etc/fstab` 的改写统一由事务管理。
- 打开 shellcheck 门禁（此前 `|| true` 吞掉全部结果），并收敛到零告警。
- 保留 v1.6.1 对 GitHub 网页上传或 ZIP 解压后入口文件为 `0644` 的兼容修复。
- 移除容易因 README 等普通文件增删而阻断安装/自更新的静态摘要清单。
- 安装前仍检查必要文件、非常规文件、越界符号链接、Bash 语法、固定入口权限和低权限 Smoke Test。
- 保持原子目录交换、命令链接恢复、事务提交标记和失败隔离。
- 加强 Debian 13/Ubuntu 环境兼容、参数校验、固定目录边界和防火墙冲突检测。

## 支持范围

- Debian / Ubuntu
- amd64 / arm64
- systemd 主机（防火墙自动回滚和服务适配需要 systemd）

## 安装

从 Git 仓库：

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends git ca-certificates

git clone --depth 1 https://github.com/xpan5201/Infra-node.git
cd Infra-node
sudo bash bootstrap.sh
```

从发行 ZIP：

```bash
unzip Infra-node-v1.6.3.zip
cd Infra-node-v1.6.3
sudo bash bootstrap.sh
```

> 发行包不含 `.git`，因此安装后 `repo.env` 不会记录提交 SHA，
> `self-update` 也无法按 SHA 锁定版本。需要锁版本请用 Git 仓库并传入完整 SHA。

无人值守确认：

```bash
sudo bash bootstrap.sh --yes
```

## 常用命令

```bash
sudo infra-node deploy            # 部署或重新应用节点基础设施配置
infra-node status                 # 查看主机、网络、Swap 和代理适配概览
sudo infra-node check             # 运行环境诊断与安全审计
sudo infra-node audit             # 只运行安全和配置偏离审计
sudo infra-node self-update main  # 从 Git main 分支原子刷新已安装程序
infra-node version                # 查看当前安装版本
```

### 预演（--dry-run）

`--dry-run` 只打印将要写入的路径与将要执行的系统变更，**不落盘**：

```bash
sudo infra-node --dry-run deploy --profile balanced
```

输出形如：

```
! dry-run 模式：不会写入任何文件或变更系统状态。
◆ 准备固定目录...
    [dry-run] would create /etc/infra-node /var/lib/infra-node /var/backups/infra-node (0755) and /var/log/infra-node (0700)
    [dry-run] would write /etc/sysctl.d/99-infra-node.conf (mode 0644)
```

`firewall configure` / `firewall disable` 同样支持预演。预演不会创建 Swap、
不会写 `/etc/fstab`、不会下发 nftables 规则。

部署时可显式控制档位和行为：

```bash
deploy_args=(
  --profile balanced       # 使用均衡资源档位
  --swap auto              # 按机器资源自动决定是否创建 Swap
  --security-updates no    # 不自动启用 unattended-upgrades
  --proxy-units auto       # 自动识别已安装的受支持代理 systemd unit
  --restart-proxy no       # 只写 drop-in，不立即重启代理服务
)
sudo infra-node deploy "${deploy_args[@]}"
```

默认不会重启代理服务。未发现受支持的代理 systemd unit 时，不创建空 drop-in。

## 防火墙

防火墙默认不自动启用。启用时只管理 `table inet infra_node_filter`，自动保留实际 SSH 监听端口，并在应用前设置 5 分钟自动回滚。确认 SSH 连接正常后，会启用独立的 `infra-node-firewall.service`，使规则在重启后恢复：

```bash
sudo infra-node firewall configure                         # 交互填写端口并启用/更新防火墙
sudo infra-node firewall configure --tcp 80,443 --udp 443 # 非交互放行端口并配置开机恢复
sudo infra-node firewall show                              # 查看自有表和开机持久化状态
sudo infra-node firewall disable                           # 删除自有表、配置和自有持久化服务
```

兼容别名：`enable` 等价于带参数的 `configure`，`status` 等价于 `show`，`remove` 等价于 `disable`。端口支持逗号分隔的单端口和范围，例如 `443,8443,10000-10100`；SSH 实际监听端口始终自动保留。

以下任一条件存在时会拒绝接管：

- UFW 活动
- firewalld 活动
- 存在其他 nftables input 基链
- 无法读取当前 nftables 状态
- 无法创建 systemd 自动回滚任务

禁用操作只删除 Infra-node 自有表、自有配置、辅助脚本和 `infra-node-firewall.service`，不清理其他防火墙规则。

## 固定目录契约

| 用途 | 路径 |
|---|---|
| 安装目录 | `/opt/infra-node` |
| 命令链接 | `/usr/local/bin/infra-node` |
| 命令别名 | `/usr/local/bin/pvf` → `/usr/local/bin/infra-node`（两级链，最终指向安装目录） |
| 配置 | `/etc/infra-node` |
| 状态 | `/var/lib/infra-node` |
| 日志 | `/var/log/infra-node/infra-node.log` |
| 事务备份 | `/var/backups/infra-node` |
| sysctl | `/etc/sysctl.d/99-infra-node.conf` |
| Swap 文件 | `/swapfile.infra-node` |
| 防火墙表 | `inet infra_node_filter` |

这些路径是安装安全契约，不接受仓库或普通环境变量覆盖。
`backup restore` 也只允许把事务恢复到上述契约内的路径，越界事务会被整批拒绝。

## 安全与回滚模型

- 所有持久化文件修改先快照到事务目录。
- 只有写入 `committed-at` 后，事务才不会被失败钩子回滚。
- 用户已确认保留的防火墙不会被后续失败钩子撤销。
- `/etc/fstab` 只由事务改写，Swap 失败恢复不单独改 fstab。
- sysctl、Swap、防火墙等运行时状态具有独立失败恢复路径。
- 自更新在 staging 目录完成结构、语法、链接和 Smoke 检查后才交换安装目录。
- root 安装场景下，仓库 Smoke Test 使用 `nobody`、清空环境、`no-new-privs` 和超时限制执行。
- 自更新不再依赖 `CHECKSUMS.sha256`；即使目标提交相同，也会重新安装 staging 树，以修复本地残留或旧文件。
- Git 操作禁止交互认证并受硬超时约束。

## 保守网络策略

项目只使用有限的主机级参数，例如 `somaxconn`、`netdev_max_backlog`、MTU 探测、安全重定向策略，以及内核已支持时的 `fq + bbr`。

项目不会写入：

- `vm.swappiness`
- 全局 TCP keepalive
- `ip_local_port_range`
- `tcp_fastopen`
- 超大 `rmem_max` / `wmem_max`

## 开发与校验

```bash
make check
```

`make check` 会执行 Bash 语法检查、入口权限回归、事务提交边界、保守网络策略、防火墙解析与渲染、代理部署边界，以及真实 Git archive 原子安装回归。

## 许可证

MIT
