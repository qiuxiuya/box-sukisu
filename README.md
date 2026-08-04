# box-sukisu

一个简单的 sukisu 模块，用于以 root 权限在后台运行代理核心（mihomo / sing-box）。模块仅管理内核进程、IPv6 开关与 QUIC 拦截，不操作完整的路由规则与 iptables。

使用了与 box4magisk 相同的配置路径与内核路径。

## 项目简介

box-sukisu 通过后台运行 `/data/adb/box/bin/<bin_name>` 启动代理核心，并将运行日志输出到 `/data/adb/box/run/core.log`。模块通过 action.sh 提供一键切换操作，并在 module.prop 的 description 字段中反馈当前状态。

## 主要功能

- 后台以 root 权限运行 mihomo / sing-box 核心
- 日志输出至 `/data/adb/box/run/core.log`，并定期轮换，防止日志过大
- 通过 action.sh 响应用户启动/停止操作
- 操作后自动更新 module.prop 的 description 字段，显示当前状态
- 支持通过 `/data/adb/box/settings.ini` 切换核心、IPv6 与 QUIC

## 安装方法

1. 确保你的设备已安装 sukisu 并已获取 root 权限。
2. 下载本模块的 zip 包，通过 sukisu Manager 安装。
3. 安装完成后，重启设备。

## 使用方法

- 进入 sukisu Manager，找到 box-sukisu 模块。
- 点击 action 按钮以切换核心运行状态。
- 每次操作后，可在模块信息中查看当前状态。
- 日志文件位于 `/data/adb/box/run/core.log`。

## 配置文件

模块仅读取 `/data/adb/box/settings.ini`：

```sh
bin_name="mihomo"   # mihomo / sing-box
ipv6="true"         # true / false
quic="false"        # true / false
```

## 注意事项

- **请勿直接操作 `/data/adb/box` 路径**，该路径属于 box4magisk 模块，直接操作可能让 box4magisk 模块无法正常使用。
- 日志轮换仅操作日志目录下的日志文件，防止误删其他文件。
- 由于模块拥有系统全部权限，涉及 `rm` 等高危操作时请务必确保安全。

## 贡献方式

欢迎提交 issue 或 pull request 参与本项目开发。

## 许可证

本项目采用 MIT License。
