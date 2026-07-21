# Infra-node

面向低配置 Debian / Ubuntu 节点机的一键基建脚本。

Infra-node 聚焦两件事：

- **主机与网络入口安全**：基础内核加固、日志限额、时间同步，以及可选的安全更新和 nftables 防火墙；
- **代理运行环境**：保守的 BBR / 队列调整、代理 systemd 服务资源限制和按需健康检查。

它不是代理安装器，也不是常驻监控面板。命令结束后立即退出，不会后台测速、巡检或轮询仓库。

> 命令示例中的 `# ...` 是说明注释，不需要删除，可以直接复制整段到 Bash 执行。

## 一键部署

```bash
sudo apt-get update                                                # 刷新 APT 软件包索引
sudo apt-get install -y --no-install-recommends git ca-certificates # 安装 Git 和 HTTPS 证书依赖

git clone --depth 1 https://github.com/xpan5201/Infra-node.git     # 仅克隆 main 分支最新快照
cd Infra-node                                                      # 进入项目目录
sudo bash bootstrap.sh                                             # 校验并安装 Infra-node，随后交互式部署基建
```

部署流程：

```text
仓库校验 → 原子安装 → 主机评估 → 操作者定制 → 基建部署 → 结果验证
```

### 只安装工具，不修改系统

```bash
sudo bash bootstrap.sh --install-only # 仅安装 infra-node 命令，不立即应用主机配置
```

安装完成后，可在需要时手动执行：

```bash
sudo infra-node deploy # 启动交互式基建部署
```

### 无人值守示例

```bash
sudo bash bootstrap.sh \
  --yes \
  --non-interactive \
  --mode auto \
  --proxy-units sing-box.service \
  --tcp-ports 443 \
  --udp-ports 443 \
  --firewall yes \
  --security-updates no
```

各参数的作用：

```text
--yes                              自动确认安装阶段的提示
--non-interactive                  禁止交互提问；所有必要选项必须通过参数给出
--mode auto                        根据 CPU、内存和磁盘自动选择资源模式
--proxy-units sing-box.service     登记需要设置资源限制和检查状态的代理 systemd unit
--tcp-ports 443                    防火墙启用时放行 TCP 443
--udp-ports 443                    防火墙启用时放行 UDP 443
--firewall yes                     启用 Infra-node 自有 nftables 防火墙
--security-updates no              不启用 unattended-upgrades 自动安全更新
```

生产环境建议使用 `--ref <tag>` 和 `--expect-commit <40位SHA>` 锁定版本：

```bash
sudo bash bootstrap.sh \
  --ref v1.6.0 \
  --expect-commit 0123456789abcdef0123456789abcdef01234567
# --ref：指定分支、标签或提交；--expect-commit：要求最终解析结果精确匹配该完整提交 SHA
```

启用防火墙前，请确认：

- 当前 SSH 实际监听端口能够被正确识别；
- 云平台安全组已放行管理端口和业务端口；
- 云平台救援控制台或串行控制台可用。

## 部署内容

### 主机与入口安全

- 只安装缺失的最小依赖，不执行系统全量升级；
- 禁用 redirect、source route、core dump 等不适合公网节点的行为；
- 启用 SYN cookies，按磁盘条件限制 journald 占用，并尝试启用系统 NTP；
- 可选启用系统原生 `unattended-upgrades`，默认关闭；
- 可选创建只管理 `table inet infra_node_filter` 的 nftables 防火墙；
- 防火墙生效后保留五分钟失联回滚窗口。

Infra-node **不修改** SSH 用户、密钥、端口和认证方式。

### 代理运行环境

- 内核支持时启用 `fq + BBR`；
- 启用 MTU probing，并按资源设置保守连接队列；
- 为登记的代理服务设置合理的 `LimitNOFILE`、`TasksMax` 和 OOM 优先级；
- 默认不重启代理服务，也不修改代理配置、证书、密钥或节点参数。

项目刻意不设置全局 keepalive、临时端口范围、超大 socket buffer 或全局 TCP Fast Open。

## 资源模式

| 模式 | 适用场景 | 调整取向 |
|---|---|---|
| `minimal` | 约 512–768 MiB 内存，或磁盘空间紧张 | 使用更小的日志限额和连接队列 |
| `balanced` | 常见 1 GiB VPS | 在资源占用和并发能力之间保持稳健均衡 |
| `performance` | 2 GiB 以上内存且至少 2 vCPU | 适度提高连接队列和服务资源上限 |
| `auto` | 默认选项 | 根据当前 CPU、内存和磁盘自动选择 |

## 常用命令

### 部署、状态和诊断

```bash
sudo infra-node deploy             # 一键部署、重新部署或重新定制节点基建
infra-node status                  # 查看主机资源、安全状态、网络参数和代理服务概览
infra-node check                   # 按需执行网络体验和已登记代理服务健康检查
infra-node check https://example.com # 使用指定 HTTP/HTTPS URL 进行连通性检查
sudo infra-node doctor             # 检查依赖缺失、配置偏离、权限问题和常见故障
sudo infra-node audit              # 执行只读安全审计，不主动修改系统配置
sudo infra-node panel              # 打开轻量命令行管理面板
infra-node version                 # 显示当前安装版本和版本元数据
```

说明：

- `status` 适合快速查看当前状态；
- `check` 会执行按需网络测试，运行结束后立即退出；
- `doctor` 更关注依赖、配置完整性和故障定位；
- `audit` 更关注安全风险和配置审计。

### 自更新

```bash
sudo infra-node self-update         # 从默认 ref 校验并原子更新已安装程序
sudo infra-node self-update main    # 明确从 main 分支更新
sudo infra-node self-update v1.6.0  # 更新或切换到指定标签
```

自更新只更新 Infra-node 程序本身，不会借此安装、升级或重启代理程序。

### 事务备份与恢复

```bash
sudo infra-node backup list         # 列出可用的配置事务备份及其 ID
sudo infra-node backup restore <ID> # 将受管系统文件恢复到指定事务的快照状态
```

`<ID>` 是 `backup list` 输出中的事务标识。恢复会修改受管系统文件，执行前请确认选择的是正确事务。

### 查看日志

```bash
sudo tail -n 200 /var/log/infra-node/infra-node.log # 查看最近 200 行 Infra-node 运行日志
sudo less /var/log/infra-node/infra-node.log        # 分页查看完整日志，按 q 退出
```

## 部署参数示例

下面的命令用于**预览**即将执行的变更，不会真正写入系统：

```bash
sudo infra-node --non-interactive deploy \
  --mode auto \
  --tcp-ports 443 \
  --udp-ports 443 \
  --proxy-units sing-box.service \
  --firewall no \
  --security-updates no \
  --dry-run
```

参数说明：

```text
--non-interactive                  不显示交互式问题
--mode auto                        自动选择资源配置档位
--tcp-ports 443                    记录需要放行的 TCP 业务端口
--udp-ports 443                    记录需要放行的 UDP 业务端口
--proxy-units sing-box.service     登记需要适配的代理服务 unit
--firewall no                      本次部署不启用 Infra-node 防火墙
--security-updates no              本次部署不启用自动安全更新
--dry-run                          只展示计划，不写文件、不加载规则、不重启服务
```

多个端口或 unit 使用英文逗号分隔，例如：

```bash
sudo infra-node deploy \
  --tcp-ports 80,443,8443 \
  --udp-ports 443,8443 \
  --proxy-units sing-box.service,xray.service
# 分别登记多个 TCP 端口、UDP 端口和代理 systemd unit
```

## 防火墙

防火墙默认不自动启用。启用时只管理 `table inet infra_node_filter`，自动保留实际 SSH 监听端口，并在应用前设置 5 分钟自动回滚：

```bash
sudo infra-node firewall disable # 仅删除 Infra-node 自有表、配置和服务，不清理其他防火墙规则
```

以下任一条件存在时，Infra-node 会拒绝接管防火墙：

- UFW 正在活动；
- firewalld 正在活动；
- nftables 中存在其他 input 基链；
- 无法可靠读取当前 nftables 状态；
- 无法确认 SSH 管理端口且风险不可接受。

## 安全与恢复

- 系统文件写入前创建事务快照，再通过临时文件原子替换；
- sysctl 只持久化当前主机实际接受的参数，不接管系统 swappiness；
- Swap 创建中断时会执行 `swapoff` 并清理半成品；
- 防火墙不清空其他 nftables 表，并提供失联自动回滚；
- 更新经过摘要、链接边界、低权限 Smoke Test 和最终启动校验；
- 更新失败会恢复旧程序、命令链接和仓库元数据；
- 日志与历史备份按数量轮转，避免长期占满低容量磁盘。

### 固定目录

```text
/opt/infra-node             Infra-node 程序安装目录
/etc/infra-node             部署状态和受管配置
/var/lib/infra-node         操作锁、运行状态和暂存数据
/var/log/infra-node         按需运行日志
/var/backups/infra-node     配置事务、防火墙和程序版本备份
/usr/local/bin/infra-node   全局命令入口
```

这些目录属于项目运行契约，不建议手动移动或将其改成符号链接。

## 支持环境

- Debian 12 / 13；
- Ubuntu 22.04 / 24.04 / 26.04；
- systemd、APT / dpkg；
- amd64 或 arm64；
- IPv4、IPv6 或双栈。

受限 OpenVZ / LXC 环境可能拒绝部分 sysctl；脚本会跳过不可用参数，不让整段部署因此失败。

## v1.6.0 更新公告

2026-07-20

- 修复面板内重复部署继承上次 Dry-run、端口和显式选项的问题；
- 以持久化提交标记统一网络、防火墙、Swap 与更新的信号回滚边界；
- Git 网络操作全部增加硬超时；同一提交不再交换安装目录或生成旧版本目录备份；
- `os-release` 改为数据解析，不再作为 root 直接 `source`；
- nftables 规则无法读取时按失败处理，避免在未知防火墙状态下继续接管；
- 删除会停止运行中代理服务的遗留 slice 迁移动作；
- 保留系统 journald 存储模式与 swappiness，只应用项目确有收益的保守参数；
- HTTP 自检限制为 HTTP/HTTPS 重定向，状态页补充未部署与临时防火墙状态；
- 修复目录交换中途失败时旧版本未自动归位，并让面板自更新后重新加载新代码；
- 命令链接恢复保持原子性，未完成事务与防火墙临时脚本均受数量或时限约束。

## 开发与许可证

```bash
make checksum
make check
```

`make check` 会执行 Bash 语法检查、摘要验证、入口权限回归测试、事务提交边界、保守网络策略、防火墙渲染和代理部署边界检查。

## 许可证

MIT
