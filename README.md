# Wind Monitor — Linux 一键安装

本仓库仅保存经过签名验证的 Linux x86_64 发布产物和在线安装脚本，不保存应用源码或任何密钥。

## 一键安装

适用于 Ubuntu / Debian x86_64 新服务器。使用具有 `sudo` 权限的账号执行：

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/muxang/wind-monitor-release/main/install.sh | sudo bash
```

安装完成后访问：

```text
http://<服务器IP>:3000
```

然后在管理页面配置 Feed Cookie、策略和 GMGN 凭据。安装后的安全默认状态为：

- Feed：等待管理员配置
- Execution Mode：`disabled`
- GMGN Runtime Participation：`false`
- Real Trading：不自动启用

## 更审慎的安装方式

如需先检查脚本再执行：

```bash
curl --proto '=https' --tlsv1.2 -fSLo install-wind-monitor.sh \
  https://raw.githubusercontent.com/muxang/wind-monitor-release/main/install.sh
less install-wind-monitor.sh
sudo bash install-wind-monitor.sh
```

## 安装器做什么

- 仅从固定公开仓库 `muxang/wind-monitor-release` 下载 Stable Release
- 不要求服务器安装 `gh`，也不要求 GitHub Token
- 仅接受固定资产名：
  - `wind-monitor-linux-x86_64`
  - `wind-monitor-updater-linux-x86_64`
  - `release-manifest.json`
  - `release-manifest.sig`
- 验证 Ed25519 manifest 签名、SHA-256、文件大小和 SemVer
- 创建独立的 `wind-monitor` 系统用户和受限目录
- 安装并启用应用服务与静默升级 timer
- 使用 systemd/journald 限制日志增长：最多约 512 MiB、保留最长 14 天，并保留至少 1 GiB 磁盘空间

## 常用检查

```bash
sudo systemctl status wind-monitor.service
sudo systemctl status wind-monitor-updater.timer
curl -fsS http://127.0.0.1:3000/healthz
journalctl -u wind-monitor.service -n 100 --no-pager
```

## 系统要求

- Ubuntu / Debian Linux x86_64
- `systemd`
- root 或 `sudo` 权限
- 能通过 HTTPS 访问 `github.com`、`api.github.com` 和 `objects.githubusercontent.com`

安装器会安装基础运行依赖。GMGN CLI 和业务凭据仍由管理页面及既有受控配置流程管理；安装器不会写入、显示或上传 Feed Cookie、GMGN Key、钱包密钥或 GitHub 凭据。