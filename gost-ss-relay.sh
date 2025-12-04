#!/usr/bin/env bash

# 一键安装 & 配置 gost 做 SS 中转（自动识别 gost 安装路径）
# 场景：客户端 <-> 本机中转(gost) <-> 国外 SS 落地(多 IP)

set -e

DEFAULT_LOCAL_START_PORT=40000   # 本机中转起始端口
DEFAULT_NODE_COUNT=1            # 默认配置 1 个中转
DEFAULT_TTL=60                  # UDP 转发通道空闲超时时间（秒）

REMOTE_HOSTS=()
REMOTE_PORTS=()
GOST_BIN=""   # 自动检测出来的 gost 可执行文件路径

install_gost() {
    if command -v gost >/dev/null 2>&1; then
        echo "检测到 gost 已安装，跳过安装步骤。"
        return
    fi

    echo "开始安装 gost ..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl
    else
        echo "未找到 apt-get 或 yum，请手动安装 curl 后重试。"
        exit 1
    fi

    # 官方安装脚本，会自动下载最新 gost
    bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install

    echo "gost 安装步骤执行完毕。"
}

detect_gost_bin() {
    # 优先用 PATH 里的 gost
    GOST_BIN="$(command -v gost 2>/dev/null || true)"

    # 如果 PATH 里没有，再检查常见目录
    if [ -z "$GOST_BIN" ]; then
        if [ -x /usr/local/bin/gost ]; then
            GOST_BIN="/usr/local/bin/gost"
        elif [ -x /usr/bin/gost ]; then
            GOST_BIN="/usr/bin/gost"
        else
            echo "找不到 gost 可执行文件，请确认安装成功后重试。"
            exit 1
        fi
    fi

    # 确保有执行权限
    if [ ! -x "$GOST_BIN" ]; then
        echo "gost 可执行文件没有执行权限，尝试赋予执行权限: $GOST_BIN"
        chmod +x "$GOST_BIN" || {
            echo "无法为 $GOST_BIN 添加执行权限，请检查权限。"
            exit 1
        }
    fi

    echo "使用 gost 路径: $GOST_BIN"
}

config_gost_relay() {
    echo
    echo "===== 配置 gost SS 中转 ====="

    read -p "本机中转起始端口 (默认 ${DEFAULT_LOCAL_START_PORT}): " LOCAL_START_PORT
    LOCAL_START_PORT=${LOCAL_START_PORT:-$DEFAULT_LOCAL_START_PORT}

    read -p "需要配置几个中转节点(对应几个 SS 落地)？(默认 ${DEFAULT_NODE_COUNT}): " NODE_COUNT
    NODE_COUNT=${NODE_COUNT:-$DEFAULT_NODE_COUNT}

    if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || [ "$NODE_COUNT" -le 0 ]; then
        echo "中转数量必须是正整数。"
        exit 1
    fi

    echo
    echo "请依次输入【国外 SS 落地节点】信息："
    echo "（这些就是你在国外服务器上跑 ss-multi-ip.sh 后看到的 IP 和端口）"
    echo

    for ((i = 0; i < NODE_COUNT; i++)); do
        idx=$((i + 1))
        read -p "第 ${idx} 个落地节点 IP 或域名: " host
        if [ -z "$host" ]; then
            echo "IP/域名不能为空。"
            exit 1
        fi

        read -p "第 ${idx} 个落地节点 端口: " port
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "端口必须是数字。"
            exit 1
        fi

        REMOTE_HOSTS[i]="$host"
        REMOTE_PORTS[i]="$port"
    done

    echo
    echo "将生成如下中转映射："
    for ((i = 0; i < NODE_COUNT; i++)); do
        local_port=$((LOCAL_START_PORT + i))
        echo "  本机中转端口 ${local_port}  =>  ${REMOTE_HOSTS[i]}:${REMOTE_PORTS[i]}"
    done
    echo

    # 组装 gost 命令
    local CMD="${GOST_BIN}"

    for ((i = 0; i < NODE_COUNT; i++)); do
        local_port=$((LOCAL_START_PORT + i))
        host="${REMOTE_HOSTS[i]}"
        rport="${REMOTE_PORTS[i]}"

        # TCP 转发
        CMD+=" -L=tcp://:${local_port}/${host}:${rport}"
        # UDP 转发（SS 的 UDP 支持）
        CMD+=" -L=udp://:${local_port}/${host}:${rport}?ttl=${DEFAULT_TTL}"
    done

    mkdir -p /etc/gost

    cat >/etc/systemd/system/gost-ss-relay.service <<SERVICEEOF
[Unit]
Description=Gost SS Relay Service (for multi-IP SS landing)
After=network.target

[Service]
ExecStart=${CMD}
Restart=on-failure
RestartSec=3
User=nobody
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    systemctl enable gost-ss-relay.service
    systemctl restart gost-ss-relay.service || true

    echo
    echo "===== gost 中转已配置完成 ====="
    echo "systemd 服务：gost-ss-relay.service"
    echo
    systemctl --no-pager status gost-ss-relay.service || true

    echo
    echo "中转节点列表（在客户端里就按下面信息添加 SS 节点）："
    for ((i = 0; i < NODE_COUNT; i++)); do
        local_port=$((LOCAL_START_PORT + i))
        host="${REMOTE_HOSTS[i]}"
        rport="${REMOTE_PORTS[i]}"
        echo "  第 $((i + 1)) 个："
        echo "    客户端服务器地址：  本机中转 IP (本机公网 IP)"
        echo "    客户端服务器端口：  ${local_port}"
        echo "    落地映射：         ${host}:${rport}"
        echo "    加密方式 & 密码：  填【落地 SS 节点】的 method 和 password（和国外那边保持一致）"
        echo
    done

    echo "提示：如果你在国外服务器上用的是 ss-multi-ip.sh，一般所有节点的 method/password 是一样的，只是 IP 和端口不同。"
}

main() {
    install_gost
    detect_gost_bin
    config_gost_relay
}

main "\$@"
