# Changelog

## Unreleased

> 更新系统补完：解决"升级了但配置没变"，并补上此前完全缺失的回滚与版本判断。

### Added

- **`self-check`**（等价于 `self-update --check`）：拉取远端 `VERSION` 与提交并比较，
  **只报告不写入**，不需要 root。此前没有任何办法回答"有没有新版本"。
- **`self-rollback [备份名|序号|latest]`**：把 `/opt/infra-node.backup.*` 里的旧版本换回来。
  不带参数时只列出可选项。旧版本目录一直躺在盘上，此前却没有任何命令能用它。
- **`self-update --apply`**：更新成功后自动重新执行一次 `deploy`。
- **`self-update --channel tag|main` 与 `--to-tag`**；`INFRA_UPDATE_CHANNEL` 默认 `tag`。
  远端取不到 tag 时回退到记录的 ref 并提示，不会卡住更新。
- **配置漂移检测**：`deploy.env` 记录的版本与当前程序版本不一致时，
  `self-update`、`status`、`audit` 都会报出来并给出修复命令。
- **降级保护**：目标版本号低于当前版本时拒绝执行，需显式 `--allow-downgrade`。
  版本号无法解析时不做新旧判断，仅比较提交。
- 自更新把**传出的那棵树的 `repo.env` 一并留档**（`.infra-node-repo.env`），
  使回滚能把 `/etc/infra-node/repo.env` 恢复到与代码相符的状态。

### Fixed

- **安装锁不可重入**：`self-update --apply` 会在 `self-update` 内部再次调用
  `deploy_run`，而 `flock` 属于打开的文件描述，第二次获取会与自身死锁。
  现在已持有锁时直接复用。
- `status` 的"配置档位"与 `audit` 的配置版本检查改为共用同一份读取函数，
  不再各自 awk `/var/lib/infra-node/deploy.env`。

### Tests

- 新增回归：版本号比较（含 `1.6.10 > 1.6.9` 与预发布后缀）、
  最新 tag 解析与排序、更新通道解析与回退、**安装锁可重入**、
  **配置漂移检测**、回滚候选列表（新→旧、排除无关目录）、
  `repo.env` 随传出树留档。

## 1.6.3 - 2026-10-05

> 接手维护版本：修复真实缺陷，并把主机网络调优做到能真正服务代理转发。

### Fixed

- **BBR 此前是静默失效的。** Debian/Ubuntu 把 `tcp_bbr` 编译成模块且默认不加载，
  而旧判据只 grep `/proc/sys/net/ipv4/tcp_available_congestion_control`，
  在全新主机上恒为假 —— 于是既不写 `fq`/`bbr`，也**不给任何提示**，
  用户以为 BBR 已开启而实际仍在跑 cubic。现在：先 `modprobe tcp_bbr`、
  重新判定、把模块写入 `/etc/modules-load.d/50-infra-node-bbr.conf` 保证重启后仍生效，
  并在内核确实不支持时明确告警而不是跳过。
- **非 root 用户下只读命令曾无法运行。** 目录创建被当成启动期硬失败，导致
  `infra-node version` / `help` 在普通用户下直接报错。现在启动期只提示，
  真正写入时才由 `core_atomic_write` / `txn_begin` 明确失败。
- **`--dry-run` 现在真的不落盘。** 此前该选项只影响时间同步与 journald 重启，仍会写入
  `/etc/sysctl.d/99-infra-node.conf`、`/etc/systemd/journald.conf.d/50-infra-node.conf`、
  代理 drop-in，创建固定目录，并在小内存主机上创建 Swap 与写 `/etc/fstab`。
  现在 `core_atomic_write` 集中拦截，各模块的目录、Swap、防火墙路径也分别短路。
- **事务恢复增加固定路径白名单。** `backup restore` 会按事务记录删除目标路径，
  此前只校验"是绝对路径"。现在任何越界路径都会让**整批恢复**在删除前中止，
  归一化后按路径分量边界比较（`/etc/apt-evil` 不会命中 `/etc/apt/`）。
- **防火墙确认后不再被失败钩子撤销。** 拆分为 `FIREWALL_APPLIED` 与 `FIREWALL_CONFIRMED`
  两个状态位；提交后、用户已确认后、从未下发运行时规则时都不再回滚。
  `disable` 改用独立钩子，不再复用 configure 的语义。
- **代理 systemd 资源限制此前从未生效。** drop-in 路径写成了
  `/etc/systemd/system/<unit>.service.d/`（即 `xray.service.service.d`），
  systemd 永不读取该目录。现改为正确的 `<unit>.d`。这是长期静默失效的功能缺陷。
- **Swap 与 `/etc/fstab` 一致性。** fstab 改写统一走事务快照，
  `network_rollback_swap` 不再修改 fstab，消除两个独立失败钩子争用同一文件、
  可能留下悬空 swap 条目导致下次开机 degraded 的问题。
- **内核缺少 IPv6 开关时不再中止整个部署。** 以 `ipv6.disable=1` 启动的主机没有
  `/proc/sys/net/ipv6`，此前 `sysctl -w` 失败会让 `deploy` 以"内核拒绝参数"为由中止。
  现在按内核实际暴露的开关过滤，并对被跳过的键给出提示。
- **打开 shellcheck 门禁。** `make check` 此前以 `|| true` 吞掉全部退出码，
  CI 里安装了 shellcheck 却拿不到结果。修复其报出的真实问题
  （`${var#"$dir"/}` 未加引号的模式展开、`!=` 右侧未加引号、`A && B || C` 误用），
  其余误报以行内定向 `disable` 并注明原因，未使用整体排除。
- **README 的网络参数清单与代码矛盾。** README 白纸黑字声明"项目不会写入
  `ip_local_port_range` / `tcp_fastopen` / 超大 `rmem_max`/`wmem_max`"，
  而 `network_build_sysctl()` 三项都会写。安装者正是依据这一段判断
  "这东西会对我机器做什么"，因此按 v1.6.3 的真实行为重写了该节。

### Added

- **代理向网络调优**（面向吞吐与转发延迟，而非通用"网络优化"）：
  - `net.ipv4.tcp_max_syn_backlog` 与 `somaxconn` 同步分档
    —— 此前只调了后者，新连接队列仍停在 1024。
  - `net.ipv4.tcp_slow_start_after_idle = 0`：代理长连接被反复复用，
    空闲后不应退回慢启动。
  - `net.ipv4.tcp_notsent_lowat = 131072`：降低转发首字节延迟。
  - `net.core.rmem_max`/`wmem_max` 与 `tcp_rmem`/`tcp_wmem` 上限
    **按实际内存自适应**：≤1 GiB 维持 4 MiB，1–4 GiB 用 8 MiB，≥4 GiB 用 16 MiB，
    小机器不会被缓冲区吃爆。
  - **UDP 缓冲**（`rmem_default`/`wmem_default`/`udp_*_min`）：QUIC / Hysteria / TUIC
    走 UDP，内核默认约 208 KiB 会在高速下丢包，此前项目完全未覆盖。
  - `net.ipv4.tcp_fastopen = 3`：降低新建连接延迟。
  - **临时端口范围仅在明显偏窄时**拓宽为 `10240 65535`
    （WSL2 默认仅 44620–48715，约 4000 个；代理大量主动外连时会 EADDRNOTAVAIL），
    已经足够宽的系统不会被改写。
- `repo.env` 新增 `CHANNEL=git|zip`，发行包安装会明确提示"无法按 SHA 锁定版本"。

### Changed

- `--profile` 的取值在参数解析阶段就校验，与 `--swap` 等选项口径一致。
- `infra-node firewall` 不带子命令时打印可用子命令，不再静默当作 `show`。
- `--verbose` 此前被解析但从未生效；现在明确提示"目前无效果"并指向日志文件，
  同时移除死配置项 `INFRA_VERBOSE`。
- 发行包命名统一为 `Infra-node-v<版本>.zip`（原为 `-fixed` 后缀，与 README 不一致）；
  `make package` 增加 `zip` 预检，并排除本地私有 `docs/` 目录。
- 新增 `.gitignore`，排除 `/docs/` 与 `/dist/`。
- 删除死代码：`core_rotate_logs`、`INFRA_LOG_KEEP`、`CORE_ORIGINAL_ARGS`、
  `UPDATE_STAGED_FROM_LOCAL`、`update_installed_commit`、`update_current_commit`。
- `audit` 改为读取模块级的 sysctl 路径，而不是硬编码 `/etc/sysctl.d/99-infra-node.conf`；
  其"禁止参数"清单同步更新（缓冲区上限与 `tcp_fastopen` 已是有意设置，不再算违规；
  新增 `tcp_ecn` / `tcp_tw_recycle` 等真正有风险的项）。
- TUI 面板的每个菜单项加了错误隔离，某个探测失败不再把操作员踢回 shell。

### Tests

- 新增回归：dry-run 零写入、dry-run 闸门早于测试模式短路、事务路径契约与越界拒绝、
  代理 drop-in 路径、防火墙回滚边界、内核不支持参数被跳过、
  **BBR 模块加载与持久化**、缓冲区按内存自适应、临时端口范围仅在偏窄时拓宽、
  **只读命令在不可写状态下仍可用且写入会明确失败**、
  **失败的 preflight 必须阻止安装**。
- 事务夹具移入固定路径契约内（原夹具落在契约外，已不再合法）。
- 平台跳过守卫 `INFRA_SMOKE_SKIP_SYMLINKS` / `SKIP_MODES` / `SKIP_SYNTAX` 仅用于
  无法提供符号链接与 POSIX 权限位的非 Linux 环境；CI 不设置这些变量。
- shellcheck 在本版本收敛到零告警。

### Verified

在真实 **Debian 13（WSL2，内核 6.18.33.2）** 上验证：
`make syntax` / `make smoke`（37 项）/ `make integration` 全部通过，shellcheck 零告警；
并实测确认 `modprobe tcp_bbr` 前 `tcp_available_congestion_control` 为 `reno cubic`、
加载后为 `reno cubic bbr`，本项目的生成配置正确写出 `bbr` + `fq`
且按 15.8 GiB 内存取到 16 MiB 缓冲上限。

## 1.6.2 maintenance hotfix - 2026-07-21

> 维护修复，不修改 `VERSION`。

### Fixed

- 移除运行时 `CHECKSUMS.sha256` 门禁，普通文件增删不再导致安装或自更新被错误阻断。
- 自更新不再因当前安装目录被修改而拒绝覆盖；即使目标 commit 相同，也会原子重装 staging 树。
- 增加 `firewall configure|apply`、`firewall show|status` 和 `firewall disable|remove` 命令别名。
- 防火墙未启用或 nftables 未安装时，`firewall show` 以正常状态返回，不再暴露底层 `No such file or directory`。
- 防火墙端口参数支持去重、前导零规范化和 `10000-10100` 范围，并限制最多 128 项。
- 防火墙确认后启用独立 systemd oneshot 持久化服务；禁用时仅删除自有表、配置、辅助脚本和自有服务。
- 防火墙确认超时后拒绝继续持久化，避免自动回滚已经触发后又重新加载未确认规则。
- 安装目标若被符号链接或普通文件占用时拒绝目录交换，防止固定安装路径被重定向。

### Tests

- 增加无摘要清单安装、同 commit 重装修复、firewall 命令帮助、范围端口和未启用状态回归。

## 1.6.2 - 2026-07-21

### Fixed

- 修复 bootstrap 在原子安装后通过 `exec` 交接部署时继承安装器 flock，造成自锁。
- 修复自动代理 unit 探测中的正常“不存在”结果触发继承 ERR trap，并输出伪崩溃信息。
- 修复首次安装目标目录尚不存在时，磁盘空间预检被静默跳过。
- 修复权限审计把 Unix mode 当十进制数比较，可能错误接受 `0444` 等权限的问题。
- 加固 SSH socket/防火墙存在性探测，避免空结果在 process substitution 中触发伪错误。
- 让 sysctl、Swap 和防火墙运行时恢复钩子尊重已提交事务，消除提交后的迟到信号回滚窗口。

### Tests

- 增加安装器锁交接、空代理 unit、首次安装磁盘预检、权限位审计和提交边界回归测试。

## 1.6.1 - 2026-07-21

### Fixed

- 修复入口文件缺少 executable bit 时，`update_verify_tree` 在任何内容诊断之前立即失败。
- 修复组合校验只返回通用退出码，无法判断摘要、语法、链接或 Smoke 子步骤的问题。
- 修复日志轮转索引移动方向错误。
- 修复 bootstrap 的 `--yes` 传递和本地 ZIP 发行包安装路径。
- 修复步骤包装器可能因 Bash 条件上下文而掩盖函数内部早期失败。
- 修复事务元数据覆盖 shell `PATH` 变量以及管道子 shell 丢失快照状态的问题。
- 修复总部署后续步骤失败时，已应用 sysctl 和新建 Swap 未恢复的问题。
- 修复防火墙在配置事务提交前过早取消自动回滚的问题。

### Improved

- 固定入口在内容摘要与语法验证通过后统一规范化为 `0755`。
- Smoke Test 以低权限、空环境、资源受限方式执行，并显示失败输出。
- 增加 Debian 13 兼容路径、事务回归、风险 sysctl 禁止项和防火墙自有表测试。
- 防火墙接管前检查 UFW、firewalld、其他 nftables input 基链和规则读取错误。
- 防火墙应用前创建 systemd 自动回滚任务；只有用户确认后取消。
- 代理适配继续限定为 systemd 资源限制，不安装、不配置、不默认重启代理服务。
