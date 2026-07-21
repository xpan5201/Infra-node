# Security Policy

请勿在公开 Issue 中提交服务器 IP、SSH 凭据、代理密钥、证书私钥、订阅地址或完整运行日志。

报告应包含：Infra-node 版本、系统版本、触发命令、脱敏后的错误上下文，以及 `/var/log/infra-node/infra-node.log` 中与故障对应的最小片段。

Infra-node 将 Git 仓库内容视为不可信输入。安装和更新必须经过文件类型、符号链接边界、完整摘要、Bash 语法和低权限 Smoke Test 校验。
