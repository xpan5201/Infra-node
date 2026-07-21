# Security Policy

请勿在公开 Issue 中提交服务器 IP、SSH 凭据、代理密钥、证书私钥、订阅地址或完整运行日志。

报告应包含：Infra-node 版本、系统版本、触发命令、脱敏后的错误上下文，以及 `/var/log/infra-node/infra-node.log` 中与故障对应的最小片段。

安装和更新会在 staging 目录检查必要文件、非常规文件、符号链接边界、Bash 语法和低权限 Smoke Test。项目不再使用容易与仓库普通改动失步的静态 `CHECKSUMS.sha256` 清单。

需要锁定生产版本时，请使用受保护的 Git tag，并为 `self-update` 或 bootstrap 提供预期的完整 commit SHA。显式 commit 校验仍然保留。
