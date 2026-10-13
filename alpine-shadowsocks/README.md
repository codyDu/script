# Alpine 3.23 Shadowsocks-rust

交互式 POSIX `sh` 安装配置脚本，支持 OpenRC / supervise-daemon 和可选 v2ray-plugin WebSocket。适合 512MB VPS：使用 `apk` 预编译的 `shadowsocks-rust-ssserver`，单线程运行，UDP 会话上限 128，不编译 Rust/Go，不自动创建 swap。实际内存使用仍取决于连接数量。

## 运行

以 root 登录 Alpine 3.23，确保 `/etc/apk/repositories` 已启用同版本的 `main` 和 `community`，不要混用 edge。需要已启动的 OpenRC 和交互终端。

下载本目录的 `install.sh`，检查内容后执行：

```sh
sh install.sh
```

按提示输入端口、算法、密码/密钥、插件选项，最后确认应用。密码/密钥需隐藏输入两遍；不一致时重新输入，一致后才检查 SS2022 格式与长度。普通 AEAD 仍不设最短长度。重复运行可重新配置现有服务。不会读取或打印旧密码，也不会生成带密码的分享链接。不要使用 `sh -x` 或将实际配置提交到 GitHub。

支持普通 AEAD：`chacha20-ietf-poly1305`、`aes-128-gcm`、`aes-256-gcm`。密码不设最短长度（包括空输入），但客户端也必须支持对应密码。SS2022 必须使用规范 Base64：`2022-blake3-aes-128-gcm` 解码后 16 字节；`2022-blake3-aes-256-gcm` 和 `2022-blake3-chacha20-poly1305` 为 32 字节。此脚本配置单一服务端密钥，不接受客户端 EIH 冒号链。密码按原文写入 JSON；上游对 `${VAR}` 形式有环境变量替换行为，请避免将这种形式当作字面密码。

端口范围 1–65535，监听 IPv4 `0.0.0.0`。脚本不修改防火墙或云安全组；按配置自行开放 TCP，无插件且使用 UDP 时也开放相同 UDP 端口。

## v2ray-plugin

已有 `/usr/local/bin/v2ray-plugin` 时先检查 `-version`。否则 x86_64、x86、aarch64 从官方固定版本 v1.3.2 的 HTTPS 发布地址安装，先检查归档成员和可执行性。其他架构需自行放置可信、适配 musl 的插件，脚本不会在小内存 VPS 上编译。无法运行或下载失败时终止。

上游 v1.3.2 发布未提供资产摘要，下载依赖 GitHub HTTPS，不宣称额外的签名/校验和验证。现有插件不会被覆盖；新安装的插件和 apk 包不会因配置回滚而卸载。

交互输入 WebSocket Host 和 path，禁止 `;` 等插件选项分隔符。Host 不会让你获得该域名的证书或控制权；TLS 应使用你拥有并指向服务器的域名。TLS 可关闭（例如由反向代理终止 TLS）或由插件直接提供。

直接 TLS 需要现有、有效、与 Host 匹配的 PEM 证书和无口令私钥绝对路径；脚本验证有效期、Host 和公私钥配对，不申请证书、不复制私钥。确保私钥仅 root 可读，续期后重启服务。

WebSocket 插件只承载 TCP，启用后脚本设置 `mode: tcp_only`。客户端需要相同算法、密码、Host、path、TLS 设置和 v2ray-plugin（客户端选项不含 `server`、`cert`、`key`）。

## 服务、配置与回滚

服务名 `ss-rust`，配置 `/etc/shadowsocks-rust/config.json`（root，0600），目录 0700；OpenRC 服务文件 `/etc/init.d/ss-rust`。服务由 root 运行以支持低端口和已有证书路径。supervise-daemon 自动重启，3 秒延迟、60 秒内最多 5 次。

```sh
rc-service ss-rust status
rc-service ss-rust restart
rc-service ss-rust stop
rc-update show default
```

每次应用前备份现有配置、服务文件和状态到 `/etc/shadowsocks-rust/backup.XXXXXX`（只对 root 开放）。配置采用同目录临时文件替换，防止写出半份 JSON。失败或可捕获信号会恢复配置、服务文件和原先的运行/自启状态。启动后等待 5 秒，检查 OpenRC 状态和 TCP 监听，再启用开机自启。这是本机启动检查；仍需用客户端验证公网、DNS 和数据传输。

断电或 SIGKILL 无法运行清理。确认没有安装进程后可移除 `/run/ss-rust-install.lock`，按备份恢复。手动回滚时，先查看备份 `state`，将 `BACKUP` 换为实际目录：

```sh
BACKUP=/etc/shadowsocks-rust/backup.XXXXXX
rc-service ss-rust stop
# 备份有文件则恢复；没有则说明安装前不存在，应删除对应新文件。
if [ -f "$BACKUP/config.json" ]; then
  cp -p "$BACKUP/config.json" /etc/shadowsocks-rust/config.json
else
  rm -f /etc/shadowsocks-rust/config.json
fi
if [ -f "$BACKUP/init" ]; then
  cp -p "$BACKUP/init" /etc/init.d/ss-rust
else
  rm -f /etc/init.d/ss-rust
fi
# 按 state 恢复 default 自启；仅当 running=yes 时重新启动。
cat "$BACKUP/state"
```

原状态 `enabled=no` 时运行 `rc-update del ss-rust default`；`enabled=yes` 时运行 `rc-update add ss-rust default`。`running=yes` 时运行 `rc-service ss-rust start`。包安装、插件安装、目录权限收紧不属于配置回滚。备份包含真实密钥，切勿上传。

已有其他名为 `ss-rust` 的服务会被备份并替换；其他名称的 Shadowsocks 服务需自行停用，避免端口冲突。脚本使用系统 DNS。测试失败时查看 OpenRC 错误；不要在故障报告粘贴未脱敏配置。

## 验证

`sh -n install.sh` 检查语法；`sh tests.sh` 测试端口边界、普通 AEAD 空/短密码、SS2022 精确长度和非规范 Base64、插件分隔符输入。测试仅使用临时合成密钥。GitHub Actions 在 Alpine 3.23 中运行这些检查并测试预编译 ssserver 的实际 TCP 启动。完整 OpenRC、插件、TLS 和 512MB 负载还需在实际 Alpine 主机验证。

官方依据：[Alpine 3.23 ssserver 包](https://pkgs.alpinelinux.org/packages?branch=v3.23&name=shadowsocks-rust-ssserver)、[Shadowsocks-rust 配置与密钥说明](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.24.0/README.md)、[v2ray-plugin](https://github.com/shadowsocks/v2ray-plugin)、[固定插件版本](https://github.com/shadowsocks/v2ray-plugin/releases/tag/v1.3.2)。
