#!/usr/bin/env bash

# GOST SS Relay 管理脚本（中转端）
# 功能：
#  1. 安装 gost
#  2. 更新 gost
#  3. 卸载 gost
#  4. 启动 gost 中转服务
#  5. 停止 gost 中转服务
#  6. 重启 gost 中转服务
#  7. 新增 gost 转发配置（单条/少量，交互式）
#  8. 查看现有 gost 配置
#  9. 删除一则 gost 配置
# 10. 配置 gost 定时重启 (crontab)
# 11. 配置自定义 TLS 证书
# 12. 批量新增 gost 转发（起始端口 + ip:port 列表）
# 13. 清空所有 gost 转发配置（危险操作，会停止中转服务）

set -e

SERVICE_NAME="gost-ss-relay.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
CONFIG_DIR="/etc/gost"
RELAY_CONFIG="${CONFIG_DIR}/relay.conf"
TLS_CONFIG="${CONFIG_DIR}/tls.conf"

DEFAULT_TTL=60   # udp 转发 ttl
GOST_BIN=""
TLS_CERT=""
TLS_KEY=""

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

ensure_root
mkdir -p "${CONFIG_DIR}"

detect_gost_bin() {
    GOST_BIN="$(command -v gost 2>/dev/null || true)"

    if [ -z "${GOST_BIN}" ]; then
        if [ -x /usr/local/bin/gost ]; then
            GOST_BIN="/usr/local/bin/gost"
        elif [ -x /usr/bin/gost ]; then
            GOST_BIN="/usr/bin/gost"
        else
            GOST_BIN=""
        fi
    fi

    if [ -n "${GOST_BIN}" ] && [ ! -x "${GOST_BIN}" ]; then
        chmod +x "${GOST_BIN}" || true
    fi
}

load_tls_config() {
    TLS_CERT=""
    TLS_KEY=""
    if [ -f "${TLS_CONFIG}" ]; then
        TLS_CERT="$(grep '^CERT=' "${TLS_CONFIG}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
        TLS_KEY="$(grep '^KEY=' "${TLS_CONFIG}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    fi
}

install_gost() {
    detect_gost_bin
    if [ -n "${GOST_BIN}" ]; then
        echo "gost 已安装在: ${GOST_BIN}"
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

    bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install

    detect_gost_bin
    if [ -z "${GOST_BIN}" ]; then
        echo "gost 安装失败，请检查。"
        exit 1
    fi
    echo "gost 安装完成，路径：${GOST_BIN}"
    "${GOST_BIN}" -V 2>/dev/null || true
}

update_gost() {
    echo "开始更新 gost 到最新版本 ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl
    else
        echo "未找到 apt-get 或 yum，请手动安装 curl 后重试。"
        exit 1
    fi

    bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install

    detect_gost_bin
    if [ -z "${GOST_BIN}" ]; then
        echo "gost 更新后无法找到可执行文件，请检查。"
        exit 1
    fi
    echo "gost 更新完成，当前版本："
    "${GOST_BIN}" -V 2>/dev/null || true
}

remove_auto_restart_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        return
    fi
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'GOST_AUTO_RESTART' > "${tmp}" || true
    crontab "${tmp}" 2>/dev/null || true
    rm -f "${tmp}"
}

uninstall_gost() {
    echo "即将卸载 gost 并删除中转服务及相关配置..."

    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload || true

    detect_gost_bin
    if [ -n "${GOST_BIN}" ]; then
        echo "删除 gost 可执行文件：${GOST_BIN}"
        rm -f "${GOST_BIN}" || true
    fi

    echo "删除 ${CONFIG_DIR} 配置目录（包括 relay.conf / tls.conf）"
    rm -rf "${CONFIG_DIR}"

    echo "移除 crontab 中的自动重启配置（如果有）"
    remove_auto_restart_cron

    echo "卸载操作完成。"
}

build_service_from_config() {
    detect_gost_bin
    if [ -z "${GOST_BIN}" ]; then
        echo "未找到 gost，请先安装（菜单 1 或 2）。"
        return 1
    fi

    if [ ! -f "${RELAY_CONFIG}" ] || ! grep -qE '^[^#[:space:]]' "${RELAY_CONFIG}" 2>/dev/null; then
        echo "当前没有任何转发配置，将停止并禁用 ${SERVICE_NAME} ..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload || true
        return 0
    fi

    load_tls_config

    local CMD
    CMD="${GOST_BIN}"

    while read -r TYPE LPORT RHOST RPORT _; do
        [ -z "${TYPE}" ] && continue
        case "${TYPE}" in
            \#*)
                continue
                ;;
        esac

        if [ -z "${LPORT}" ] || [ -z "${RHOST}" ] || [ -z "${RPORT}" ]; then
            echo "跳过非法配置行：${TYPE} ${LPORT} ${RHOST} ${RPORT}"
            continue
        fi

        case "${TYPE}" in
            tcp)
                CMD+=" -L=tcp://:${LPORT}/${RHOST}:${RPORT}"
                CMD+=" -L=udp://:${LPORT}/${RHOST}:${RPORT}?ttl=${DEFAULT_TTL}"
                ;;
            tls)
                local tls_params=""
                if [ -n "${TLS_CERT}" ] && [ -n "${TLS_KEY}" ]; then
                    tls_params="?cert=${TLS_CERT}&key=${TLS_KEY}"
                fi
                CMD+=" -L=tls://:${LPORT}/${RHOST}:${RPORT}${tls_params}"
                ;;
            *)
                echo "未知类型 ${TYPE}，仅支持 tcp / tls，已跳过该行。"
                ;;
        esac
    done < "${RELAY_CONFIG}"

    if [ "${CMD}" = "${GOST_BIN}" ]; then
        echo "未生成任何有效转发规则，取消写入 service。"
        return 1
    fi

    cat >"${SERVICE_FILE}" <<SERVICEEOF
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
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl restart "${SERVICE_NAME}" || true

    echo "已根据配置重建并重启 ${SERVICE_NAME}。"
    systemctl --no-pager status "${SERVICE_NAME}" || true
}

start_gost_service() {
    if [ ! -f "${SERVICE_FILE}" ]; then
        echo "service 文件不存在，请先新增转发配置（菜单 7 或 12）。"
        return
    fi
    systemctl start "${SERVICE_NAME}" || true
    systemctl --no-pager status "${SERVICE_NAME}" || true
}

stop_gost_service() {
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl --no-pager status "${SERVICE_NAME}" || true
}

restart_gost_service() {
    if [ ! -f "${SERVICE_FILE}" ]; then
        echo "service 文件不存在，请先新增转发配置（菜单 7 或 12）。"
        return
    fi
    systemctl restart "${SERVICE_NAME}" || true
    systemctl --no-pager status "${SERVICE_NAME}" || true
}

add_relay_config() {
    echo
    echo "===== 新增 GOST 转发配置（适合单条/少量） ====="
    echo "支持类型："
    echo "  tcp  - 普通 tcp+udp 端口转发（适合 SS 中转）"
    echo "  tls  - TLS 包裹的转发（tls://，可配合自定义证书）"

    while true; do
        echo
        echo "---- 新增一条转发规则 ----"

        read -r -p "转发类型 (tcp/tls，默认 tcp): " TYPE
        TYPE=${TYPE:-tcp}

        case "${TYPE}" in
            tcp|tls)
                ;;
            *)
                echo "不支持的类型：${TYPE}，仅支持 tcp / tls。请重新输入。"
                continue
                ;;
        esac

        read -r -p "本机监听端口 (local port): " LPORT
        if ! [[ "${LPORT}" =~ ^[0-9]+$ ]]; then
            echo "端口必须是数字，请重新来一条。"
            continue
        fi

        read -r -p "远端目标 IP 或域名 (remote host): " RHOST
        if [ -z "${RHOST}" ]; then
            echo "远端地址不能为空，请重新来一条。"
            continue
        fi

        read -r -p "远端目标端口 (remote port): " RPORT
        if ! [[ "${RPORT}" =~ ^[0-9]+$ ]]; then
            echo "端口必须是数字，请重新来一条。"
            continue
        fi

        echo "${TYPE} ${LPORT} ${RHOST} ${RPORT}" >> "${RELAY_CONFIG}"
        echo "✅ 已写入配置：${TYPE}  本地=${LPORT}  远端=${RHOST}:${RPORT}"

        read -r -p "还要继续新增一条吗？(Y/n): " more
        more=${more:-Y}
        case "${more}" in
            n|N)
                break
                ;;
            *)
                ;;
        esac
    done

    echo
    echo "配置已更新，正在重建并重启服务..."
    build_service_from_config
}

batch_add_relay_config() {
    echo
    echo "===== 批量新增 GOST 转发配置（起始端口 + ip:port 列表） ====="
    echo "说明："
    echo "  - 先选一个统一的转发类型（tcp/tls）"
    echo "  - 再指定本机起始端口，比如 30000 或 40000"
    echo "  - 然后按行输入多个 落地 ip:port（例如 1.2.3.4:20000），最后输入 done 结束"
    echo

    read -r -p "转发类型 (tcp/tls，默认 tcp): " TYPE
    TYPE=${TYPE:-tcp}

    case "${TYPE}" in
        tcp|tls)
            ;;
        *)
            echo "不支持的类型：${TYPE}，仅支持 tcp / tls。"
            return
            ;;
    esac

    read -r -p "本机起始监听端口 (local start port): " LOCAL_START_PORT
    if ! [[ "${LOCAL_START_PORT}" =~ ^[0-9]+$ ]]; then
        echo "端口必须是数字。"
        return
    fi

    echo
    echo "请按行输入远端 落地 ip:port，输入 done 结束，例如："
    echo "  108.165.171.141:20000"
    echo "  23.136.164.122:20001"
    echo "  done"
    echo

    local idx=0
    while true; do
        read -r -p "第 $((idx+1)) 条 (ip:port 或 done): " line
        [ -z "${line}" ] && continue

        case "${line}" in
            done|DONE|Done)
                break
                ;;
        esac

        case "${line}" in
            *:*)
                local RHOST="${line%%:*}"
                local RPORT="${line##*:}"
                ;;
            *)
                echo "格式错误，应为 ip:port，例如 1.2.3.4:20000"
                continue
                ;;
        esac

        if [ -z "${RHOST}" ] || [ -z "${RPORT}" ]; then
            echo "ip 或端口为空，跳过。"
            continue
        fi
        if ! [[ "${RPORT}" =~ ^[0-9]+$ ]]; then
            echo "远端端口必须是数字，跳过这一条。"
            continue
        fi

        local LPORT=$((LOCAL_START_PORT + idx))
        echo "${TYPE} ${LPORT} ${RHOST} ${RPORT}" >> "${RELAY_CONFIG}"
        echo "✅ 已添加：${TYPE}  本地=${LPORT}  远端=${RHOST}:${RPORT}"

        idx=$((idx+1))
    done

    if [ "${idx}" -eq 0 ]; then
        echo "未添加任何配置。"
        return
    fi

    echo
    echo "共添加 ${idx} 条配置，正在重建并重启服务..."
    build_service_from_config
}

view_relay_config() {
    echo
    echo "===== 当前 GOST 转发配置 (${RELAY_CONFIG}) ====="
    if [ ! -f "${RELAY_CONFIG}" ] || ! grep -qE '^[^#[:space:]]' "${RELAY_CONFIG}" 2>/dev/null; then
        echo "当前没有任何转发配置。"
    else
        local idx=1
        while read -r TYPE LPORT RHOST RPORT _; do
            [ -z "${TYPE}" ] && continue
            case "${TYPE}" in
                \#*)
                    continue
                    ;;
            esac
            printf "  [%02d] 类型=%-3s  本地=%-5s  远端=%s:%s\n" "${idx}" "${TYPE}" "${LPORT}" "${RHOST}" "${RPORT}"
            idx=$((idx + 1))
        done < "${RELAY_CONFIG}"
    fi

    load_tls_config
    echo
    echo "TLS 证书配置："
    if [ -n "${TLS_CERT}" ] && [ -n "${TLS_KEY}" ]; then
        echo "  CERT = ${TLS_CERT}"
        echo "  KEY  = ${TLS_KEY}"
    else
        echo "  未配置 TLS 证书。"
    fi

    echo
    echo "服务状态："
    systemctl --no-pager status "${SERVICE_NAME}" 2>/dev/null || echo "  ${SERVICE_NAME} 当前未运行或未创建。"
}

delete_relay_config() {
    if [ ! -f "${RELAY_CONFIG}" ] || ! grep -qE '^[^#[:space:]]' "${RELAY_CONFIG}" 2>/dev/null; then
        echo "当前没有任何转发配置可删除。"
        return
    fi

    echo
    echo "===== 删除一则 GOST 转发配置 ====="

    local line_no=0
    local idx=1
    local -a map_lines=()
    local -a display_lines=()

    while IFS= read -r line; do
        line_no=$((line_no + 1))
        [ -z "${line}" ] && continue
        case "${line}" in
            \#*)
                continue
                ;;
        esac

        set -- ${line}
        local TYPE="$1"
        local LPORT="$2"
        local RHOST="$3"
        local RPORT="$4"

        printf "  [%02d] 行号=%-3s  类型=%-3s  本地=%-5s  远端=%s:%s\n" \
            "${idx}" "${line_no}" "${TYPE}" "${LPORT}" "${RHOST}" "${RPORT}"

        map_lines[${idx}]="${line_no}"
        display_lines[${idx}]="${line}"
        idx=$((idx + 1))
    done < "${RELAY_CONFIG}"

    if [ "${idx}" -eq 1 ]; then
        echo "当前没有有效配置。"
        return
    fi

    echo
    read -r -p "请输入要删除的配置序号 (数字，0 取消): " choose
    if ! [[ "${choose}" =~ ^[0-9]+$ ]]; then
        echo "输入必须是数字。"
        return
    fi
    if [ "${choose}" -eq 0 ]; then
        echo "已取消删除。"
        return
    fi

    local target_line="${map_lines[${choose}]}"
    if [ -z "${target_line}" ]; then
        echo "无效序号。"
        return
    fi

    echo "即将删除：${display_lines[${choose}]}"
    read -r -p "确认删除？(y/N): " confirm
    case "${confirm}" in
        y|Y)
            sed -i "${target_line}d" "${RELAY_CONFIG}"
            echo "已删除第 ${target_line} 行配置。"
            ;;
        *)
            echo "已取消删除。"
            return
            ;;
    esac

    build_service_from_config
}

clear_all_relay_config() {
    echo
    echo "===== 清空所有 GOST 转发配置（危险操作） ====="
    if [ ! -f "${RELAY_CONFIG}" ] || ! grep -qE '^[^#[:space:]]' "${RELAY_CONFIG}" 2>/dev/null; then
        echo "当前 ${RELAY_CONFIG} 中本来就没有有效配置。"
        return
    fi

    local backup="${RELAY_CONFIG}.$(date +%Y%m%d%H%M%S).bak"
    echo "将备份当前配置到：${backup}"
    cp "${RELAY_CONFIG}" "${backup}"

    echo
    read -r -p "确认清空所有转发配置，并停止 gost 中转服务？(y/N): " c
    case "${c}" in
        y|Y)
            : > "${RELAY_CONFIG}"
            echo "已清空 ${RELAY_CONFIG}。"
            build_service_from_config
            echo "中转服务已根据空配置停止并移除（如有）。"
            echo "原配置备份为：${backup}"
            ;;
        *)
            echo "已取消清空。"
            ;;
    esac
}

configure_auto_restart() {
    echo
    echo "===== 配置 GOST 定时重启 ====="

    if ! command -v crontab >/dev/null 2>&1; then
        echo "当前系统没有 crontab 命令，无法配置定时任务。"
        return
    fi

    echo "当前 crontab 中的 GOST 自动重启配置："
    crontab -l 2>/dev/null | grep 'GOST_AUTO_RESTART' || echo "  无"

    echo
    echo "1) 设置/修改 每日定时重启"
    echo "2) 取消自动重启"
    read -r -p "请选择 (1/2，默认 1): " opt
    opt=${opt:-1}

    case "${opt}" in
        1)
            read -r -p "请输入每天重启的小时 (0-23，默认 4): " H
            H=${H:-4}
            read -r -p "请输入每天重启的分钟 (0-59，默认 0): " M
            M=${M:-0}
            if ! [[ "${H}" =~ ^[0-9]+$ ]] || ! [[ "${M}" =~ ^[0-9]+$ ]]; then
                echo "小时和分钟必须是数字。"
                return
            fi
            if [ "${H}" -lt 0 ] || [ "${H}" -gt 23 ] || [ "${M}" -lt 0 ] || [ "${M}" -gt 59 ]; then
                echo "小时或分钟超出范围。"
                return
            fi

            local tmp
            tmp="$(mktemp)"
            crontab -l 2>/dev/null | grep -v 'GOST_AUTO_RESTART' > "${tmp}" || true
            echo "${M} ${H} * * * systemctl restart ${SERVICE_NAME} # GOST_AUTO_RESTART" >> "${tmp}"
            crontab "${tmp}"
            rm -f "${tmp}"
            echo "已设置每天 ${H}:${M} 自动重启 ${SERVICE_NAME}。"
            ;;
        2)
            remove_auto_restart_cron
            echo "已取消 GOST 自动重启。"
            ;;
        *)
            echo "已取消。"
            ;;
    esac
}

configure_tls_cert() {
    echo
    echo "===== 配置 TLS 证书（用于 tls:// 转发） ====="
    load_tls_config
    echo "当前 TLS 配置："
    if [ -n "${TLS_CERT}" ] && [ -n "${TLS_KEY}" ]; then
        echo "  CERT = ${TLS_CERT}"
        echo "  KEY  = ${TLS_KEY}"
    else
        echo "  未配置。"
    fi

    echo
    echo "1) 设置/修改 TLS 证书路径"
    echo "2) 清除 TLS 配置"
    read -r -p "请选择 (1/2，默认 1): " opt
    opt=${opt:-1}

    case "${opt}" in
        1)
            read -r -p "请输入证书文件路径 (cert.pem): " new_cert
            read -r -p "请输入私钥文件路径 (key.pem): " new_key
            if [ -z "${new_cert}" ] || [ -z "${new_key}" ]; then
                echo "路径不能为空。"
                return
            fi
            echo "CERT=${new_cert}" > "${TLS_CONFIG}"
            echo "KEY=${new_key}" >> "${TLS_CONFIG}"
            echo "已写入 ${TLS_CONFIG}"
            build_service_from_config
            echo "已根据最新 TLS 配置重建并重启服务（如有 tls 类型转发规则）。"
            ;;
        2)
            rm -f "${TLS_CONFIG}"
            echo "已清除 TLS 配置。"
            build_service_from_config
            ;;
        *)
            echo "已取消。"
            ;;
    esac
}

show_menu() {
    echo
    echo "========== GOST SS Relay 管理脚本 =========="
    echo " 1) 安装 gost"
    echo " 2) 更新 gost"
    echo " 3) 卸载 gost"
    echo "-------------------------------------------"
    echo " 4) 启动 gost 中转服务"
    echo " 5) 停止 gost 中转服务"
    echo " 6) 重启 gost 中转服务"
    echo "-------------------------------------------"
    echo " 7) 新增 gost 转发配置（单条/少量）"
    echo " 8) 查看现有 gost 配置"
    echo " 9) 删除一则 gost 配置"
    echo "10) 配置 gost 定时重启 (crontab)"
    echo "11) 配置自定义 TLS 证书"
    echo "12) 批量新增 gost 转发（起始端口 + ip:port 列表）"
    echo "13) 清空所有 gost 转发配置（危险操作）"
    echo "-------------------------------------------"
    echo " 0) 退出"
    echo "==========================================="
}

main_loop() {
    while true; do
        show_menu
        read -r -p "请输入选项 [0-13]: " choice
        case "${choice}" in
            1) install_gost ;;
            2) update_gost ;;
            3) uninstall_gost ;;
            4) start_gost_service ;;
            5) stop_gost_service ;;
            6) restart_gost_service ;;
            7) add_relay_config ;;
            8) view_relay_config ;;
            9) delete_relay_config ;;
            10) configure_auto_restart ;;
            11) configure_tls_cert ;;
            12) batch_add_relay_config ;;
            13) clear_all_relay_config ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "无效选项：${choice}"
                ;;
        esac
    done
}

main_loop
