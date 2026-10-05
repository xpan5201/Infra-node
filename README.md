# Infra-node

Infra-node 是用于代理节点 VPS 的**主机基础设施层**。它提前完成系统评估、基础安全、代理向网络调优、日志与时间同步、可选 Swap、代理 systemd 资源限制适配，以及可选 nftables 主机防火墙。

> 项目不安装代理程序，不生成代理配置、证书、密钥或订阅，不修改 SSH 用户/密钥/认证方式，也不运行常驻测速、监控或自动更新代理任务。

## v1.6.4 重点

- **代理 systemd 资源限制的 drop-in 路径修正为 `<unit>.service.d/`。**
  systemd 从 **unit 全名**（含类型后缀）加 `.d` 读取 drop-in：`xray.service`
  对应 `xray.service.d/`，不是 `xray.d/`。v1.6.3 曾把这条本来正确的路径改错，
  导致资源限制第二次静默失效；已在真实 systemd 257 上实测判定后改回。
- **更新系统补完。** 新增 `self-check`（只读查新版本）、`self-rollback`
  （回滚到上一次自更新前的版本）、`self-update --apply`（更新后自动重新部署）；
  默认更新通道改为跟随**发行 tag**；并新增**配置漂移检测** —— 升级后如果没重新
  `deploy`，新版本引入的主机参数不会生效，现在会被报出来。详见「更新、回滚与配置漂移」。
- **自适应补完。** 容器内不再写内核网络参数或创建 Swap（会影响到宿主机）；
  写入 sysctl 前检测是否有其它文件在争用同一批参数；创建 Swap 前按实际大小校验磁盘余量；
  代理 drop-in **只增不减**（`LimitNOFILE` 与 `TasksMax` 都不会把已有的更高值调低）；
  受支持的代理 service 名单从 7 个扩到 16 个；`status` 会提示档位是否需要重新适配。
- **本地检出不可用时会说明原因**，不再静默改用远端克隆（此前"从本地这棵树安装"
  可能实际装的是远端 ref，且全程无提示）。
- 修正 README 中与代码矛盾的网络参数清单（此前声明不写 `tcp_fastopen`、
  `ip_local_port_range`、大缓冲区，而代码三项都会写）。

## 支持范围

- Debian / Ubuntu
- amd64 / arm64
- systemd 主机（防火墙自动回滚和服务适配需要 systemd）

## 安装

推荐从 [Releases](https://github.com/xpan5201/Infra-node/releases) 页面获取：
那里的 ZIP 对应已打 tag 的版本，比跟随 `main` 稳定。

从发行 ZIP：

```bash
# 先从 Releases 页面下载 Infra-node-v1.6.4.zip
unzip Infra-node-v1.6.4.zip
cd Infra-node-v1.6.4
sudo bash bootstrap.sh
```

从 Git 仓库（锁定到已发布的 tag）：

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends git ca-certificates

git clone --depth 1 --branch v1.6.4 https://github.com/xpan5201/Infra-node.git
cd Infra-node
sudo bash bootstrap.sh
```

> 想跟随最新提交，把 `--branch v1.6.4` 换成 `--branch main`。

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
infra-node self-check             # 检查有没有新版本（只读，不需要 root）
sudo infra-node self-update       # 原子刷新已安装程序
sudo infra-node self-rollback     # 回滚到自更新前的版本
infra-node version                # 查看当前安装版本
```

## 更新、回滚与配置漂移

### 更新通道

默认通道是 `tag`：`self-update` 只跟随**最新发行 tag**。因此往 `main` 推提交
不会立刻影响已安装的机器，只有打了 tag 的版本才会被选中。
远端取不到任何 tag 时会**回退**到记录的 ref 并给出提示，不会因此卡住更新。

```bash
sudo infra-node self-update                 # 更新到最新 tag
sudo infra-node self-update --channel main  # 本次改为跟随 main 分支
sudo infra-node self-update --to-tag        # 本次强制走最新 tag
sudo infra-node self-update v1.6.3          # 指定 ref
sudo infra-node self-update main <40位SHA>  # 指定 ref 并锁定提交
```

`self-check` 只读取远端并报告，不写入任何东西：

```bash
infra-node self-check          # 等价于 infra-node self-update --check
```

### 更新后需要重新部署

主机配置（sysctl / journald / 代理 drop-in）是由**部署时的程序版本**生成的，
而 `self-update` 只替换代码。升级后若新增了调优项，不重新 `deploy` 就不会生效 ——
程序会比对版本并主动提示，`status` 与 `audit` 也会报告这类漂移：

```
! 已应用的主机配置由 v1.6.2 生成，当前程序是 v1.6.3。
! 新版本引入的主机参数在重新部署前不会生效：sudo infra-node deploy
```

也可以让它在更新成功后直接接着做：

```bash
sudo infra-node self-update --apply    # 更新成功后自动重新执行一次 deploy
```

### 回滚

每次自更新都会把旧版本保留在 `/opt/infra-node.backup.<时间戳>`（默认保留 5 份）。

```bash
sudo infra-node self-rollback          # 只列出可回滚的版本，不做任何改动
sudo infra-node self-rollback latest   # 回滚到最近一次
sudo infra-node self-rollback 2        # 按列表序号
```

回滚同样需要重新 `deploy` 才能让配置与回滚后的版本对齐，命令会提示。

### 降级保护

目标版本号低于当前版本时 `self-update` 会**拒绝执行**（旧版本留在原地），
除非显式声明：

```bash
sudo infra-node self-update --allow-downgrade v1.6.2
```

> 版本号无法解析时不做新旧判断，仅比较提交。

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

## 网络调优

调优目标是**代理转发的吞吐与延迟**，不是通用"网络优化"。所有取值随主机资源档位或内存自适应，
且写入前逐个探测内核是否暴露该开关，不支持的键会跳过并明确提示。

### BBR

Debian / Ubuntu 把 `tcp_bbr` 编译成模块且**默认不加载**，此时
`/proc/sys/net/ipv4/tcp_available_congestion_control` 只有 `reno cubic`。
部署时会：

1. `modprobe tcp_bbr`；
2. 重新判定，可用才写入 `net.core.default_qdisc = fq` 与
   `net.ipv4.tcp_congestion_control = bbr`；
3. 写入 `/etc/modules-load.d/50-infra-node-bbr.conf`，保证重启时模块先于
   `sysctl.d` 加载，BBR 不会在重启后静默退回 cubic。

内核确实不提供 BBR 时会明确告警，而不是无提示地跳过。

### 参数总表

| 参数 | 取值 | 目的 |
|---|---|---|
| `net.core.somaxconn` | 2048 / 4096 / 8192（按档位） | 提升并发连接上限 |
| `net.core.netdev_max_backlog` | 同上 | 高包速率下减少丢包 |
| `net.ipv4.tcp_max_syn_backlog` | 同上 | 与 `somaxconn` 同步，避免半连接队列成为瓶颈 |
| `net.ipv4.tcp_mtu_probing` | `1` | PMTU 黑洞下仍能连通 |
| `net.ipv4.tcp_syncookies` | `1` | SYN 洪泛防护 |
| `net.ipv4/ipv6.conf.*.accept_redirects` | `0` | 拒绝 ICMP 重定向篡改路由 |
| `net.ipv4.conf.*.send_redirects` | `0` | 不充当路由器 |
| `net.ipv4/ipv6.conf.*.accept_source_route` | `0` | 拒绝源路由 |
| `net.ipv4.tcp_slow_start_after_idle` | `0` | 代理长连接大量复用，空闲后不应退回慢启动 |
| `net.ipv4.tcp_notsent_lowat` | `131072` | 降低转发首字节延迟 |
| `net.core.rmem_max` / `wmem_max` | 4 / 8 / 16 MiB（按内存） | 带宽时延积上限 |
| `net.ipv4.tcp_rmem` / `tcp_wmem` | 上限同上 | 让自动调优能跟到新上限 |
| `net.core.rmem_default` / `wmem_default` | 同上 | 未显式设置缓冲的 socket 同样受益 |
| `net.ipv4.udp_rmem_min` / `udp_wmem_min` | `8192` | QUIC / Hysteria / TUIC 走 UDP |
| `net.ipv4.tcp_fastopen` | `3` | 降低新建连接延迟 |
| `net.ipv4.ip_local_port_range` | 仅当跨度 < 28000 时改为 `10240 65535` | 代理大量主动外连时避免 `EADDRNOTAVAIL` |
| `net.core.default_qdisc` + `net.ipv4.tcp_congestion_control` | `fq` + `bbr`（内核支持时） | 拥塞控制与调度器 |

缓冲上限按内存自适应：`< 1 GiB` → 4 MiB，`1–4 GiB` → 8 MiB，`≥ 4 GiB` → 16 MiB，
小机器不会被缓冲区吃爆。端口范围**只拓宽不缩窄**，本来已足够宽的系统原样保留。

### 明确不写入

- `vm.swappiness`（不干预内核换页倾向）
- 全局 TCP keepalive（`net.ipv4.tcp_keepalive_*`）
- `net.ipv4.tcp_ecn`
- 任何 `tcp_tw_recycle` 之类已废弃或已知不安全的参数
- 不修改 SSH 用户、密钥或认证方式

上述禁止项与 `infra-node audit` 的检查清单是同一份判据。

## 开发与校验

```bash
make check
```

`make check` 会执行 Bash 语法检查、入口权限回归、事务提交边界、网络调参策略、防火墙解析与渲染、代理部署边界，以及真实 Git archive 原子安装回归。

## 许可证

MIT
