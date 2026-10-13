#!/bin/sh
# Alpine 3.23; never invoke with sh -x (secrets are read locally).
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
die() { printf '%s\n' "$*" >&2; exit 1; }
ask() { printf '%s' "$1" >&2; IFS= read -r answer || die '输入已结束'; }
valid_port() {
    case $1 in ''|*[!0-9]*|0*) return 1;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
key_bytes() {
    case $1 in
        aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) printf 0;;
        2022-blake3-aes-128-gcm) printf 16;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf 32;;
        *) return 1;;
    esac
}
validate_key() {
    bytes=$(key_bytes "$1") || return 1
    [ "$bytes" -ne 0 ] || return 0
    case $2 in ''|*[!A-Za-z0-9+/=]*) return 1;; esac
    printf '%s' "$2" | base64 -d > "$tmp/key" 2>/dev/null || return 1
    [ "$(wc -c < "$tmp/key" | tr -d ' ')" = "$bytes" ] || return 1
    [ "$(base64 < "$tmp/key" | tr -d '\n')" = "$2" ]
}
safe_option() { case $1 in ''|*[!A-Za-z0-9._/:@-]*) return 1;; esac; }
cleanup() {
    code=$?
    trap - EXIT HUP INT TERM
    [ -z "$tty_state" ] || stty "$tty_state" < /dev/tty || :
    if [ "$transaction" = yes ]; then
        rc-service ss-rust stop >/dev/null 2>&1 || :
        for item in config.json init; do
            case $item in config.json) target=$config;; init) target=$service;; esac
            if [ -f "$backup/$item" ]; then cp -p "$backup/$item" "$target"; else rm -f "$target"; fi
        done
        [ "$enabled" = yes ] || rc-update del ss-rust default >/dev/null 2>&1 || :
        if [ "$running" = yes ]; then rc-service ss-rust start >&2 || printf '%s\n' '旧服务恢复失败，请检查备份。' >&2; fi
        printf '已回滚配置和服务文件，备份：%s\n' "$backup" >&2
    fi
    [ -z "$tmp" ] || rm -rf "$tmp"
    [ "$locked" = no ] || rmdir /run/ss-rust-install.lock
    exit "$code"
}
main() {
    [ "$(id -u)" = 0 ] || die '请以 root 运行'
    [ -r /etc/alpine-release ] || die '仅支持 Alpine Linux 3.23'
    case $(cat /etc/alpine-release) in 3.23|3.23.*) :;; *) die '仅支持 Alpine 3.23';; esac
    command -v rc-service >/dev/null || die '需要 OpenRC'
    command -v supervise-daemon >/dev/null || die '需要 supervise-daemon'
    mkdir /run/ss-rust-install.lock 2>/dev/null || die '已有安装进程或遗留锁：/run/ss-rust-install.lock'
    locked=yes
    tmp=$(mktemp -d /var/tmp/ss-rust.XXXXXX)
    arch=$(apk --print-arch)
    printf 'Alpine 架构：%s\n' "$arch"
    apk update
    apk add --no-cache shadowsocks-rust-ssserver jq curl ca-certificates openssl || die '请启用同版本 v3.23/community，勿混用 edge'
    ssserver --version
    while :; do ask '监听端口 [9999]：'; port=${answer:-9999}; valid_port "$port" && break; printf '%s\n' '端口须为 1–65535（无前导零）'; done
    printf '%s\n' '算法：chacha20-ietf-poly1305 / aes-128-gcm / aes-256-gcm' '或 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm / 2022-blake3-chacha20-poly1305'
    while :; do ask '算法 [chacha20-ietf-poly1305]：'; method=${answer:-chacha20-ietf-poly1305}; key_bytes "$method" >/dev/null && break; done
    while :; do
        printf '%s' '密码/SS2022 Base64 密钥（隐藏输入；普通 AEAD 无最短长度）：' >&2
        tty_state=$(stty -g < /dev/tty)
        stty -echo < /dev/tty
        IFS= read -r secret < /dev/tty || die '密钥输入失败'
        printf '\n%s' '请再次输入密码/密钥（隐藏输入）：' >&2
        IFS= read -r confirmation < /dev/tty || die '确认输入失败'
        stty "$tty_state" < /dev/tty; tty_state=
        printf '\n' >&2
        if [ "$secret" != "$confirmation" ]; then
            unset secret confirmation
            printf '%s\n' '两次输入不一致，请重新输入。' >&2
            continue
        fi
        unset confirmation
        validate_key "$method" "$secret" && break
        printf '%s\n' 'SS2022 须为规范 Base64：AES128 解码 16 字节，其余 32 字节。' >&2
    done
    # Secret goes through stdin and a private file, never argv/environment.
    printf '%s' "$secret" > "$tmp/password"
    unset secret
    plugin=; options=; mode=tcp_and_udp
    ask '安装/启用 v2ray-plugin WebSocket？[y/N]：'
    case $answer in y|Y)
        plugin=/usr/local/bin/v2ray-plugin
        if [ ! -x "$plugin" ]; then
            case $arch in x86_64) asset=amd64;; x86) asset=386;; aarch64) asset=arm64;; *) die '此架构不自动下载插件，请先提供 /usr/local/bin/v2ray-plugin';; esac
            asset=v2ray-plugin-linux-$asset-v1.3.2.tar.gz
            curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 "https://github.com/shadowsocks/v2ray-plugin/releases/download/v1.3.2/$asset" -o "$tmp/plugin.tar.gz"
            tar -tzf "$tmp/plugin.tar.gz" > "$tmp/members"
            member=$(sed -n '/^v2ray-plugin_linux_\(amd64\|386\|arm64\)$/p' "$tmp/members")
            [ -n "$member" ] || die '插件归档内容不符合预期'
            tar -xOzf "$tmp/plugin.tar.gz" "$member" > "$tmp/plugin"
            chmod 700 "$tmp/plugin"
            "$tmp/plugin" -version >/dev/null || die '插件无法在本架构运行'
            mkdir -p /usr/local/bin
            cp "$tmp/plugin" /usr/local/bin/.v2ray-plugin.new
            chmod 755 /usr/local/bin/.v2ray-plugin.new
            mv /usr/local/bin/.v2ray-plugin.new "$plugin"
        fi
        "$plugin" -version >/dev/null || die '现有插件不可用'
        while :; do ask 'WebSocket Host（如 example.com）：'; host=$answer; safe_option "$host" && break; done
        while :; do ask 'WebSocket path [/]：'; ws_path=${answer:-/}; case $ws_path in /*) safe_option "$ws_path" && break;; esac; done
        options="server;mode=websocket;host=$host;path=$ws_path"
        ask '由插件直接提供 TLS？[y/N]：'
        case $answer in y|Y)
            ask '已有 PEM 证书绝对路径：'; cert=$answer
            ask '已有 PEM 私钥绝对路径：'; key=$answer
            for file in "$cert" "$key"; do case $file in /*) :;; *) die 'TLS 必须使用绝对路径';; esac; safe_option "$file" && [ -r "$file" ] || die 'TLS 文件不可读或路径含插件分隔符'; done
            openssl x509 -in "$cert" -noout -checkend 0 >/dev/null || die '证书无效或已过期'
            openssl x509 -in "$cert" -noout -checkhost "$host" >/dev/null || die '证书与 Host 不匹配'
            openssl x509 -in "$cert" -pubkey -noout > "$tmp/cert.pub"
            openssl pkey -in "$key" -passin pass: -pubout > "$tmp/key.pub" 2>/dev/null || die '私钥需有效且无口令'
            cmp -s "$tmp/cert.pub" "$tmp/key.pub" || die '证书和私钥不匹配'
            options="$options;tls;cert=$cert;key=$key"
        ;; n|N|'') :;; *) die 'TLS 选项须为 y 或 n';; esac
        mode=tcp_only
    ;; n|N|'') :;; *) die '插件选项须为 y 或 n';; esac
    jq -n --rawfile password "$tmp/password" --arg method "$method" --argjson port "$port" --arg plugin "$plugin" --arg opts "$options" --arg mode "$mode" '{server:"0.0.0.0",server_port:$port,password:$password,method:$method,mode:$mode,udp_max_associations:128,runtime:{mode:"single_thread"}} + (if $plugin == "" then {} else {plugin:$plugin,plugin_opts:$opts} end)' > "$tmp/config.json"
    rm -f "$tmp/password" "$tmp/key"
    jq -e . "$tmp/config.json" >/dev/null
    printf '即将配置端口 %s、算法 %s、模式 %s（不会显示密钥）。\n' "$port" "$method" "$mode"
    ask '应用并启动？[y/N]：'; case $answer in y|Y) :;; *) die '已取消';; esac
    for file in /etc/shadowsocks-rust "$config" "$service"; do [ ! -L "$file" ] || die '拒绝修改符号链接配置'; done
    mkdir -p /etc/shadowsocks-rust
    chmod 700 /etc/shadowsocks-rust
    backup=$(mktemp -d /etc/shadowsocks-rust/backup.XXXXXX)
    [ ! -f "$config" ] || cp -p "$config" "$backup/config.json"
    [ ! -f "$service" ] || cp -p "$service" "$backup/init"
    [ ! -e /etc/runlevels/default/ss-rust ] || enabled=yes
    rc-service ss-rust status >/dev/null 2>&1 && running=yes
    printf 'running=%s\nenabled=%s\n' "$running" "$enabled" > "$backup/state"
    transaction=yes
    [ "$running" = no ] || rc-service ss-rust stop
    cp "$tmp/config.json" /etc/shadowsocks-rust/.config.new
    chmod 600 /etc/shadowsocks-rust/.config.new
    mv /etc/shadowsocks-rust/.config.new "$config"
    cat > "$tmp/init" <<'OPENRC'
#!/sbin/openrc-run
# Managed by alpine-shadowsocks/install.sh
description="Shadowsocks-rust server"
supervisor="supervise-daemon"
command="/usr/bin/ssserver"
command_args="-c /etc/shadowsocks-rust/config.json"
respawn_delay=3
respawn_max=5
respawn_period=60
depend() { need net; }
start_pre() { checkpath -d -m 0700 /etc/shadowsocks-rust; }
OPENRC
    cp "$tmp/init" /etc/init.d/.ss-rust.new
    chmod 755 /etc/init.d/.ss-rust.new
    mv /etc/init.d/.ss-rust.new "$service"
    rc-service ss-rust start
    sleep 5
    rc-service ss-rust status
    # Check the actual listener, not only the supervisor process.
    hexport=$(printf '%04X' "$port")
    awk -v p="$hexport" '$2 ~ (":" p "$") && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 || die 'TCP 监听未就绪'
    rc-update add ss-rust default
    transaction=no
    printf '配置成功。备份：%s\n检查：rc-service ss-rust status\n' "$backup"
}
tmp= tty_state= backup=
transaction=no locked=no running=no enabled=no
config=/etc/shadowsocks-rust/config.json
service=/etc/init.d/ss-rust
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
case ${1-} in --help) printf '%s\n' '用法：sh install.sh（Alpine 3.23 root 交互安装）';; '') main;; *) die '未知参数';; esac
