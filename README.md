# Infra-node

Infra-node 是用于代理节点 VPS 的**主机基础设施层**。它提前完成系统评估、基础安全、保守网络调优、日志与时间同步、可选 Swap、代理 systemd 资源限制适配，以及可选 nftables 主机防火墙。

> 项目不安装代理程序，不生成代理配置、证书、密钥或订阅，不修改 SSH 用户/密钥/认证方式，也不运行常驻测速、监控或自动更新代理任务。

## v1.6.1 修复重点

- 修复 GitHub 网页上传或 ZIP 解压后入口文件为 `0644` 时，安装器在 `update_verify_tree` 阶段立即退出的问题。
- 校验顺序改为：文件类型与链接边界 → 完整摘要 → Bash 语法 → 固定入口权限规范化 → 低权限 Smoke Test。
- 每个失败子项都会输出明确原因；Smoke Test 失败时直接显示前 40 行输出并写入日志。
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
unzip Infra-node-v1.6.1-fixed.zip
cd Infra-node-v1.6.1-fixed
sudo bash bootstrap.sh
```

无人值守确认：

```bash
sudo bash bootstrap.sh --yes
```

## 常用命令

```bash
sudo infra-node deploy
infra-node status
sudo infra-node check
sudo infra-node audit
sudo infra-node self-update main
infra-node version
```

部署时可显式控制档位和行为：

```bash
sudo infra-node deploy \
  --profile balanced \
  --swap auto \
  --security-updates no \
  --proxy-units auto \
  --restart-proxy no
```

默认不会重启代理服务。未发现受支持的代理 systemd unit 时，不创建空 drop-in。

## 防火墙

防火墙默认不自动启用。启用时只管理 `table inet infra_node_filter`，自动保留实际 SSH 监听端口，并在应用前设置 5 分钟自动回滚：

```bash
sudo infra-node firewall enable --tcp 80,443 --udp 443
sudo infra-node firewall status
sudo infra-node firewall disable
```

以下任一条件存在时会拒绝接管：

- UFW 活动
- firewalld 活动
- 存在其他 nftables input 基链
- 无法读取当前 nftables 状态
- 无法创建 systemd 自动回滚任务

禁用操作只删除 Infra-node 自有表和自有配置，不清理其他防火墙规则。

## 固定目录契约

| 用途 | 路径 |
|---|---|
| 安装目录 | `/opt/infra-node` |
| 命令链接 | `/usr/local/bin/infra-node`, `/usr/local/bin/pvf` |
| 配置 | `/etc/infra-node` |
| 状态 | `/var/lib/infra-node` |
| 日志 | `/var/log/infra-node/infra-node.log` |
| 事务备份 | `/var/backups/infra-node` |

这些目录是安装安全契约，不接受仓库或普通环境变量覆盖。

## 安全与回滚模型

- 所有持久化文件修改先快照到事务目录。
- 只有写入 `committed-at` 后，事务才不会被失败钩子回滚。
- sysctl、Swap、防火墙等运行时状态具有独立失败恢复路径。
- 自更新在 staging 目录完成摘要、语法、链接和 Smoke 校验后才交换安装目录。
- root 安装场景下，仓库 Smoke Test 使用 `nobody`、清空环境、`no-new-privs` 和超时限制执行。
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
make checksum
make check
```

`make check` 会执行 Bash 语法检查、摘要验证、入口权限回归测试、事务提交边界、保守网络策略、防火墙渲染和代理部署边界检查。

## 许可证

MIT
