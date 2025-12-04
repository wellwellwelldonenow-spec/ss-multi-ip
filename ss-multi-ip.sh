#!/usr/bin/env bash

# 多 IP 服务器一键生成 Shadowsocks 节点，不同 IP 落地
# 参考：xrayL.sh 思路，每个 IP 对应一个入站 + 出站 + 路由规则

DEFAULT_START_PORT=20000           # 默认起始端口
DEFAULT_SS_METHOD="aes-256-gcm"   # 默认加密方式（可改成 2022-blake3-* 等）
DEFAULT_SS_PASSWORD="password123" # 默认密码，建议安装后自己改

# 获取本机所有 IP 地址（IPv4/IPv6）
IP_ADDRESSES=($(hostname -I))

install_xray() {
    echo "安装 Xray..."

    if command -v xrayL >/dev/null 2>&1; then
        echo "已检测到 xrayL，跳过安装"
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y wget unzip
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wget unzip
    else
        echo "未找到 apt-get 或 yum，请手动安装 wget unzip 后重试"
        exit 1
    fi

    cd /tmp || exit 1

    wget -O Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip"
    unzip -o Xray-linux-64.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL

    mkdir -p /etc/xrayL

    cat >/etc/systemd/system/xrayL.service <<SERVICEEOF
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.toml
Restart=on-failure
User=nobody
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    systemctl enable xrayL.service
    systemctl restart xrayL.service

    echo "Xray 安装完成."
}

config_ss_multi_ip() {
    if [ ${#IP_ADDRESSES[@]} -eq 0 ]; then
        echo "未检测到任何 IP 地址，退出。"
        exit 1
    fi

    echo "检测到的本机 IP："
    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        echo "  $((i + 1)). ${IP_ADDRESSES[i]}"
    done

    read -p "起始端口 (默认 ${DEFAULT_START_PORT}): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}

    read -p "Shadowsocks 加密方式 method (默认 ${DEFAULT_SS_METHOD}): " SS_METHOD
    SS_METHOD=${SS_METHOD:-$DEFAULT_SS_METHOD}

    read -p "Shadowsocks 密码 password (默认 ${DEFAULT_SS_PASSWORD}): " SS_PASSWORD
    SS_PASSWORD=${SS_PASSWORD:-$DEFAULT_SS_PASSWORD}

    read -p "网络类型 network (tcp/udp/tcp,udp，默认 tcp,udp): " SS_NETWORK
    SS_NETWORK=${SS_NETWORK:-"tcp,udp"}

    read -p "是否使用全部 IP 建立节点? (Y/n): " USE_ALL
    USE_ALL=${USE_ALL:-Y}

    SELECTED_IPS=()
    if [[ "$USE_ALL" =~ ^[Nn]$ ]]; then
        echo "请输入要使用的 IP 序号，空格分隔，例如: 1 3 4"
        read -p "> " index_list
        for idx in $index_list; do
            n=$((idx - 1))
            if [ $n -ge 0 ] && [ $n -lt ${#IP_ADDRESSES[@]} ]; then
                SELECTED_IPS+=("${IP_ADDRESSES[n]}")
            fi
        done
    else
        SELECTED_IPS=("${IP_ADDRESSES[@]}")
    fi

    if [ ${#SELECTED_IPS[@]} -eq 0 ]; then
        echo "没有选择任何 IP，退出。"
        exit 1
    fi

    echo "将为以下 IP 生成 Shadowsocks 节点："
    for ((i = 0; i < ${#SELECTED_IPS[@]}; i++)); do
        echo "  $((i + 1)). ${SELECTED_IPS[i]} -> 端口 $((START_PORT + i))"
    done

    # 生成 config.toml 内容
    config_content=""

    # 简单 log 配置
    config_content+="[log]\n"
    config_content+="loglevel = \"warning\"\n\n"

    for ((i = 0; i < ${#SELECTED_IPS[@]}; i++)); do
        port=$((START_PORT + i))
        tag="ss_tag_$((i + 1))"
        ip="${SELECTED_IPS[i]}"

        # 入站 Shadowsocks
        config_content+="[[inbounds]]\n"
        config_content+="port = ${port}\n"
        config_content+="protocol = \"shadowsocks\"\n"
        config_content+="tag = \"${tag}\"\n"
        config_content+="[inbounds.settings]\n"
        config_content+="method = \"${SS_METHOD}\"\n"
        config_content+="password = \"${SS_PASSWORD}\"\n"
        config_content+="network = \"${SS_NETWORK}\"\n\n"

        # 出站 freedom，指定 sendThrough 为对应 IP，实现不同 IP 落地
        config_content+="[[outbounds]]\n"
        config_content+="sendThrough = \"${ip}\"\n"
        config_content+="protocol = \"freedom\"\n"
        config_content+="tag = \"${tag}\"\n\n"

        # 路由：每个入站只走自己对应的出站
        config_content+="[[routing.rules]]\n"
        config_content+="type = \"field\"\n"
        config_content+="inboundTag = \"${tag}\"\n"
        config_content+="outboundTag = \"${tag}\"\n\n\n"
    done

    echo -e "${config_content}" > /etc/xrayL/config.toml

    systemctl restart xrayL.service
    systemctl --no-pager status xrayL.service || true

    echo
    echo "Shadowsocks 多 IP 配置生成完成。"
    echo "起始端口: ${START_PORT}"
    local end_port=$((START_PORT + ${#SELECTED_IPS[@]} - 1))
    echo "结束端口: ${end_port}"
    echo "加密方式: ${SS_METHOD}"
    echo "密码: ${SS_PASSWORD}"
    echo "网络: ${SS_NETWORK}"
    echo
    echo "节点信息:"
    for ((i = 0; i < ${#SELECTED_IPS[@]}; i++)); do
        port=$((START_PORT + i))
        ip="${SELECTED_IPS[i]}"
        echo "  第$((i + 1))个：IP=${ip}  端口=${port}  method=${SS_METHOD}  password=${SS_PASSWORD}"
    done
}

main() {
    [ -x "$(command -v xrayL)" ] || install_xray
    config_ss_multi_ip
}

main "$@"
