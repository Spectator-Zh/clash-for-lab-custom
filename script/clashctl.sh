# shellcheck disable=SC2148
# shellcheck disable=SC2155

_set_system_proxy() {
    # Ensure config files exist before reading
    [ ! -f "$MIHOMO_CONFIG_RUNTIME" ] && {
        _failcat "运行时配置文件不存在: $MIHOMO_CONFIG_RUNTIME"
        return 1
    }
    
    local auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    [ -n "$auth" ] && auth=$auth@

    local http_proxy_addr="http://${auth}127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy

    # Ensure mixin config directory exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新系统代理配置"
        return 1
    }
}

_unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY

    # Ensure mixin config exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新系统代理配置"
    }
}

function clashon() {
    # Ensure config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RUNTIME")"
    
    # Merge configuration using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    # 检查端口冲突并显示分配结果
    _resolve_port_conflicts "$MIHOMO_CONFIG_RUNTIME" true
    
    # Start mihomo process
    if start_mihomo; then
        # Wait for mihomo to fully start
        sleep 2
        
        # 验证实际端口并设置端口变量
        _verify_actual_ports
        
        # 保存端口状态并设置系统代理
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT"
        _set_system_proxy
        _okcat '已开启代理环境'
    else
        _failcat '代理启动失败'
        return 1
    fi
}

# 验证实际监听端口与配置是否一致
_verify_actual_ports() {
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    [ ! -f "$log_file" ] && return 0
    
    # Extract actual listening ports from log
    # Try both old format (Mixed) and new format (HTTP proxy)
    local actual_proxy_port=$(grep "Mixed(http+socks) proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
    [ -z "$actual_proxy_port" ] && actual_proxy_port=$(grep "HTTP proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
    
    local actual_ui_port=$(grep "RESTful API listening at:" "$log_file" | tail -1 | sed -n 's/.*:\([0-9]\+\)[^0-9]*$/\1/p')
    local actual_dns_port=$(grep "DNS server(UDP) listening at:" "$log_file" | tail -1 | sed -n 's/.*\[::\]:\([0-9]*\).*/\1/p')
    
    # 从配置文件获取期望端口进行比较
    local config_proxy_port=$("$BIN_YQ" '.mixed-port // 7890' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_addr=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_port=${config_ui_addr##*:}
    local config_dns_addr=$("$BIN_YQ" '.dns.listen // "0.0.0.0:15353"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_dns_port=${config_dns_addr##*:}
    
    local port_changed=false
    
    # 设置实际监听端口到变量
    if [ -n "$actual_proxy_port" ]; then
        MIXED_PORT=$actual_proxy_port
        [ "$actual_proxy_port" != "$config_proxy_port" ] && {
            _failcat "🔄" "mihomo自动调整代理端口: $config_proxy_port → $actual_proxy_port"
            port_changed=true
        }
    else
        MIXED_PORT=$config_proxy_port
    fi
    
    if [ -n "$actual_ui_port" ]; then
        UI_PORT=$actual_ui_port
        [ "$actual_ui_port" != "$config_ui_port" ] && {
            _failcat "🔄" "mihomo自动调整UI端口: $config_ui_port → $actual_ui_port"
            port_changed=true
        }
    else
        UI_PORT=$config_ui_port
    fi
    
    if [ -n "$actual_dns_port" ]; then
        DNS_PORT=$actual_dns_port
        [ "$actual_dns_port" != "$config_dns_port" ] && {
            _failcat "🔄" "mihomo自动调整DNS端口: $config_dns_port → $actual_dns_port"
            port_changed=true
        }
    else
        DNS_PORT=$config_dns_port
    fi
    
    # 只有当端口有变化时才显示最终端口分配并重新设置系统代理
    if [ "$port_changed" = true ]; then
        _okcat "最终端口分配 - 代理:$MIXED_PORT UI:$UI_PORT DNS:$DNS_PORT"
        # 保存实际监听端口到状态文件
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT"
        # 端口变化时重新设置系统代理环境变量
        _set_system_proxy
    fi
}

watch_proxy() {
    # 新开交互式shell，且无代理变量时
    [ -z "$http_proxy" ] && [[ $- == *i* ]] && {
        # 检查用户是否启用系统代理
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable // true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)

        # 仅当用户启用系统代理且 mihomo 进程运行时，自动写入环境变量
        if [ "$system_proxy_status" = "true" ] && is_mihomo_running; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _set_system_proxy
        fi
    }
}

function clashoff() {
    # Stop mihomo process
    stop_mihomo
    _unset_system_proxy
    _okcat '已关闭代理环境'
}

function clashrestart() {
    _okcat "正在重启代理服务..."
    { clashoff && clashon; } >&/dev/null && _okcat "代理服务重启成功"
}

_mihomo_api_headers() {
    local runtime_file=${1:-$MIHOMO_CONFIG_RUNTIME}
    local secret
    secret=$("$BIN_YQ" '.secret // ""' "$runtime_file" 2>/dev/null)
    printf '%s\n' "-H" "Content-Type: application/json"
    [ -n "$secret" ] && printf '%s\n' "-H" "Authorization: Bearer ${secret}"
}

function clashreload() {
    if ! is_mihomo_running; then
        _failcat "mihomo 进程未运行，改为直接启动"
        clashon
        return $?
    fi

    _valid_config "$MIHOMO_CONFIG_RUNTIME" || {
        _failcat "运行时配置校验失败，无法 reload"
        return 1
    }

    _get_ui_port
    local endpoint="http://127.0.0.1:${UI_PORT}/configs?force=true"
    local headers=()
    while IFS= read -r header; do
        headers+=("$header")
    done < <(_mihomo_api_headers)

    if curl --silent --show-error --fail \
        "${headers[@]}" \
        --request PUT \
        --data "{\"path\":\"runtime.yaml\"}" \
        "$endpoint" >/dev/null; then
        _verify_actual_ports
        _okcat "配置热重载成功"
        return 0
    fi

    _failcat "API reload 失败，回退到 restart"
    clashrestart
}

function clashproxy() {
    case "$1" in
    on)
        if is_mihomo_running; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _set_system_proxy
            _okcat '已开启系统代理'
        else
            _failcat '无法开启系统代理：mihomo 进程未运行'
            return 1
        fi
        ;;
    off)
        _unset_system_proxy
        _okcat '已关闭系统代理'
        ;;
    status)
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
        if [ "$system_proxy_status" = "false" ]; then
            _failcat "系统代理：关闭"
            return 1
        fi
        
        if is_mihomo_running; then
            _okcat "系统代理：开启
http_proxy： $http_proxy
socks_proxy：$all_proxy"
        else
            _failcat "系统代理：配置为开启，但 mihomo 进程未运行"
            return 1
        fi
        ;;
    *)
        cat <<EOF
用法: clashproxy [on|off|status]
    on      开启系统代理
    off     关闭系统代理
    status  查看系统代理状态
EOF
        ;;
    esac
}

function clashport() {
    local action=$1
    shift || true

    case "$action" in
    ""|status)
        _load_port_preferences
        _get_proxy_port
        local mode_msg
        if [ "$PORT_PREF_MODE" = "manual" ] && [ -n "$PORT_PREF_VALUE" ]; then
            mode_msg="固定(${PORT_PREF_VALUE})"
        else
            mode_msg="自动"
        fi
        _okcat "端口模式：$mode_msg"
        _okcat "当前代理端口：$MIXED_PORT"
        ;;
    auto)
        _save_port_preferences auto ""
        _okcat "已切换为自动分配代理端口"
        if is_mihomo_running; then
            _okcat "正在重新应用配置..."
            clashrestart
        fi
        ;;
    set|manual)
        local manual_port=$1
        local prefer_auto=false

        while true; do
            if [ -z "$manual_port" ]; then
                printf "请输入想要固定的代理端口 [1024-65535]: "
                read -r manual_port
            fi

            if [ -z "$manual_port" ]; then
                _failcat "未输入端口"
                continue
            fi

            if ! [[ $manual_port =~ ^[0-9]+$ ]] || [ "$manual_port" -lt 1024 ] || [ "$manual_port" -gt 65535 ]; then
                _failcat "端口号无效，请输入 1024-65535 之间的数字"
                manual_port=""
                continue
            fi

            if _is_already_in_use "$manual_port" "$BIN_KERNEL_NAME"; then
                _failcat '🎯' "端口 $manual_port 已被占用"
                printf "选择操作 [r]重新输入/[a]自动分配: "
                read -r choice
                case "$choice" in
                [aA])
                    prefer_auto=true
                    break
                    ;;
                [rR])
                    manual_port=""
                    continue
                    ;;
                *)
                    manual_port=""
                    continue
                    ;;
                esac
            fi

            break
        done

        if [ "$prefer_auto" = true ]; then
            _save_port_preferences auto ""
            _okcat "已切换为自动分配代理端口"
        else
            _save_port_preferences manual "$manual_port"
            _okcat "已固定代理端口：$manual_port"
        fi

        if is_mihomo_running; then
            _okcat "正在重新应用配置..."
            clashrestart
        fi
        ;;
    *)
        cat <<EOF
用法: clashport [status|auto|set <port>]
    status          查看当前代理端口模式与端口
    auto            切换为自动分配代理端口
    set <port>      固定代理端口，端口冲突时可选择重新输入或自动分配
EOF
        ;;
    esac
}

function clashstatus() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    
    # Show subscription URL
    local subscription_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    if [ -n "$subscription_url" ]; then
        _okcat "订阅地址: $subscription_url"
    else
        _failcat "订阅地址: 未设置"
    fi
    
    if is_mihomo_running; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        local kernel_version=""
        [ -x "$BIN_MIHOMO" ] && kernel_version=$("$BIN_MIHOMO" -v 2>/dev/null | head -n1)
        _okcat "mihomo 进程状态: 运行中"
        [ -n "$kernel_version" ] && _okcat "内核版本: $kernel_version"
        _okcat "进程 PID: $pid"
        _okcat "运行时间: ${uptime:-未知}"
        _okcat "配置文件: $MIHOMO_CONFIG_RUNTIME"
        _okcat "日志文件: $log_file"
        
        # Show proxy port status
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _okcat "代理端口: $MIXED_PORT"
            _okcat "管理端口: $UI_PORT"
            _okcat "DNS端口: $DNS_PORT"
        else
            _failcat "配置文件不存在，无法获取端口信息"
        fi
        
        # Show system proxy status
        clashproxy status
    else
        _failcat "mihomo 进程状态: 未运行"
        [ -f "$pid_file" ] && {
            _failcat "发现残留 PID 文件，已清理"
            rm -f "$pid_file"
        }
        return 1
    fi
}

function clashui() {
    _get_ui_port
    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

function clashtui() {
    local clashctl_bin="${MIHOMO_BASE_DIR}/bin/clashctl-tui"

    # 懒加载: 首次使用时下载 TUI 工具
    if [ ! -x "$clashctl_bin" ]; then
        _download_tui || return 1
    fi

    # 确保 mihomo 运行
    if ! is_mihomo_running; then
        _okcat "正在启动 mihomo..."
        clashon || return 1
    fi

    # 获取实际端口
    _verify_actual_ports
    _get_ui_port

    # 检查端口可用性
    if ! _is_bind "$UI_PORT" 2>/dev/null; then
        _failcat "API 端口 ${UI_PORT} 未监听，请执行 clash status 检查"
        return 1
    fi

    # 生成配置并启动 TUI
    local endpoint="http://127.0.0.1:${UI_PORT}"
    local api_secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_file="${MIHOMO_BASE_DIR}/config/clashctl.ron"

    _generate_clashctl_config "mihomo-local" "$endpoint" "$api_secret" > "$config_file" || {
        _failcat "生成配置失败"
        return 1
    }

    _okcat "正在连接 $endpoint ..."
    "$clashctl_bin" --config-path "$config_file" tui
}

_merge_config_restart() {
    # Use user-accessible temp directory instead of /tmp
    local backup="${MIHOMO_BASE_DIR}/config/runtime.backup"
    
    # Ensure config directory exists
    mkdir -p "$(dirname "$backup")"
    
    # Backup current runtime config
    cat "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null > "$backup"
    
    # Merge configurations using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    # Validate merged configuration
    _valid_config "$MIHOMO_CONFIG_RUNTIME" || {
        # Restore backup on validation failure
        cat "$backup" > "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null
        _error_quit "验证失败：请检查 Mixin 配置"
    }
    
    # Clean up backup file
    rm -f "$backup"
    
    clashrestart
}

function clashsecret() {
    case "$#" in
    0)
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _okcat "当前密钥：$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)"
        else
            _failcat "运行时配置文件不存在"
        fi
        ;;
    1)
        # Ensure mixin config directory exists
        mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
        "$BIN_YQ" -i ".secret = \"$1\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local tun_status=$("$BIN_YQ" '.tun.enable' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        # shellcheck disable=SC2015
        [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
    else
        _failcat 'Tun 状态：配置文件不存在'
        return 1
    fi
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart
    sleep 0.5s
    
    # Check if mihomo is running and tun mode is working
    if is_mihomo_running; then
        local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
        # Check recent log entries for tun mode status
        if [ -f "$log_file" ]; then
            # Look for tun-related messages in the last few lines
            tail -20 "$log_file" 2>/dev/null | grep -i "tun" >/dev/null 2>&1 && {
                _okcat "Tun 模式已开启"
            } || {
                _okcat "Tun 模式已开启 (请检查日志确认状态: $log_file)"
            }
        else
            _okcat "Tun 模式已开启"
        fi
    else
        _failcat "Tun 模式配置已更新，但 mihomo 进程未运行"
    fi
}

function clashtun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

_lanstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local lan_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        if [ "$lan_status" = 'true' ]; then
            _okcat '局域网访问：已开启'
        else
            _failcat '局域网访问：已关闭'
        fi
    else
        _failcat '局域网访问：配置文件不存在'
        return 1
    fi
}

_lanoff() {
    _lanstatus >/dev/null 2>&1 && {
        local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        [ "$current_status" = 'false' ] && return 0
    }

    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.allow-lan = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _merge_config_restart && _okcat "局域网访问已关闭"
}

_lanon() {
    local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
    [ "$current_status" = 'true' ] && return 0

    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.allow-lan = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _merge_config_restart && _okcat "局域网访问已开启"
}

function clashlan() {
    case "$1" in
    on)
        _lanon
        ;;
    off)
        _lanoff
        ;;
    status)
        _lanstatus
        ;;
    *)
        _lanstatus
        ;;
    esac
}

function clashsubscribe() {
    case "$#" in
    0)
        # Show current subscription URL
        local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
        if [ -n "$url" ]; then
            _okcat "当前订阅地址: $url"
        else
            _failcat "未设置订阅地址"
            return 1
        fi
        ;;
    1)
        # Set new subscription URL
        local new_url="$1"
        if [ "${new_url:0:4}" != "http" ]; then
            _failcat "无效的订阅地址，必须以 http 或 https 开头"
            return 1
        fi
        
        # Save URL
        mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
        echo "$new_url" > "$MIHOMO_CONFIG_URL"
        _okcat "订阅地址已设置: $new_url"
        
        # Ask if user wants to update immediately
        printf "是否立即更新订阅配置? [y/N]: "
        read -r response
        case "$response" in
        [yY]|[yY][eE][sS])
            clashupdate "$new_url"
            ;;
        *)
            _okcat "订阅地址已保存，使用 'clash update' 命令更新配置"
            ;;
        esac
        ;;
    *)
        cat <<EOF
用法: clash subscribe [URL]
    无参数      显示当前订阅地址
    URL         设置新的订阅地址
EOF
        ;;
    esac
}

function clashupdate() {
    local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        tail "${MIHOMO_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${MIHOMO_CONFIG_RAW} 进行更新..."
        url="file://$MIHOMO_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置用户级定时任务
    [ "$is_auto" = true ] && {
        # Persist URL for cron runs (cron executes `mihomoctl update`, which reads MIHOMO_CONFIG_URL).
        [ "${url:0:4}" = "http" ] && {
            mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
            echo "$url" > "$MIHOMO_CONFIG_URL"
        }

        # Check if crontab entry already exists
        crontab -l 2>/dev/null | grep -qs 'mihomoctl_auto_update' || {
            # Add user-level crontab entry (every 2 days at midnight)
            (crontab -l 2>/dev/null; echo "0 0 */2 * * $_SHELL -i -c 'mihomoctl update' # mihomoctl_auto_update") | crontab -
        }
        _okcat "已设置用户级定时更新订阅 (每2天执行一次)" && return 0
    }

    _okcat '👌' "正在下载：原配置已备份..."
    
    # Ensure directories exist and backup using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RAW_BAK")" "$(dirname "$MIHOMO_UPDATE_LOG")"
    cp "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" 2>/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        # Restore backup using user permissions
        cp "$MIHOMO_CONFIG_RAW_BAK" "$MIHOMO_CONFIG_RAW" 2>/dev/null
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" >> "${MIHOMO_UPDATE_LOG}"
        return 1
    }

    _download_config "$MIHOMO_CONFIG_RAW" "$url" || { _rollback "下载失败：已回滚配置" || true; return 1; }
    _valid_config "$MIHOMO_CONFIG_RAW" || { _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG" || true; return 1; }

    _merge_config_restart || return 1
    _okcat '🍃' '订阅更新成功'
    
    # Save URL and log success using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
    echo "$url" > "$MIHOMO_CONFIG_URL"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" >> "${MIHOMO_UPDATE_LOG}"
}

function clashmihomo() {
    local action=$1
    shift || true

    case "$action" in
    "" | version)
        if [ -x "$BIN_MIHOMO" ]; then
            "$BIN_MIHOMO" -v
        else
            _failcat "未找到已安装的 mihomo 内核: $BIN_MIHOMO"
            return 1
        fi
        ;;
    update)
        local arch version url restart_after=true was_running=false downloaded
        arch=$(uname -m)
        version="latest"
        url=""

        while [ $# -gt 0 ]; do
            case "$1" in
            --version)
                version=$2
                shift 2
                ;;
            --url)
                url=$2
                shift 2
                ;;
            --no-restart)
                restart_after=false
                shift
                ;;
            http://* | https://*)
                url=$1
                shift
                ;;
            *)
                version=$1
                shift
                ;;
            esac
        done

        mkdir -p "$ZIP_BASE_DIR"

        if [ -n "$url" ]; then
            downloaded="${ZIP_BASE_DIR}/$(basename "$url")"
            _okcat "正在下载自定义 mihomo 内核..."
            curl --progress-bar --show-error --fail --location --connect-timeout 15 --retry 2 \
                --output "$downloaded" "$url" || {
                rm -f "$downloaded"
                _failcat "自定义 mihomo 下载失败"
                return 1
            }
        else
            version=$(_normalize_mihomo_version "$version")
            downloaded=$(_download_mihomo "$arch" "$version") || return 1
        fi

        is_mihomo_running && was_running=true
        _replace_installed_mihomo "$downloaded" "$version" || return 1

        if [ -x "$BIN_MIHOMO" ]; then
            _okcat "当前 mihomo 版本：$("$BIN_MIHOMO" -v | head -n1)"
        fi

        if [ "$was_running" = true ] && [ "$restart_after" = true ]; then
            _okcat "检测到 mihomo 正在运行，正在重启以应用新内核..."
            clashrestart || return 1
        fi

        _okcat "mihomo 内核更新完成"
        ;;
    help | -h | --help)
        cat <<EOF
用法: clash mihomo [version|update]
    version                         查看当前 mihomo 内核版本
    update [latest|vX.Y.Z]          更新到指定或最新 mihomo 版本
    update --url URL                从自定义下载地址更新 mihomo
    update --no-restart             替换内核后不自动重启
EOF
        ;;
    *)
        _failcat "未知的 mihomo 子命令: $action"
        return 1
        ;;
    esac
}

function clashmixin() {
    case "$1" in
    -e)
        vim "$MIHOMO_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less -f "$MIHOMO_CONFIG_RUNTIME"
        ;;
    *)
        less -f "$MIHOMO_CONFIG_MIXIN"
        ;;
    esac
}

function clashctl() {
    case "$1" in
    on)
        clashon
        ;;
    off)
        clashoff
        ;;
    reload)
        clashreload
        ;;
    restart)
        clashrestart
        ;;
    ui)
        clashui
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    proxy)
        shift
        clashproxy "$@"
        ;;
    port)
        shift
        clashport "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    lan)
        shift
        clashlan "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    subscribe)
        shift
        clashsubscribe "$@"
        ;;
    update)
        shift
        clashupdate "$@"
        ;;
    mihomo)
        shift
        clashmihomo "$@"
        ;;
    tui)
        clashtui
        ;;
    *)
        cat <<EOF

Usage:
    clash COMMAND  [OPTION]
    mihomo COMMAND [OPTION]
    mihomoctl COMMAND [OPTION]

Commands:
    on                      开启代理
    off                     关闭代理
    reload                  热重载配置
    restart                 重启代理服务
    status                  进程运行状态
    tui                     交互式终端界面（TUI）
    ui                      Web 控制台地址
    proxy    [on|off|status]       系统代理环境变量
    port     [status|auto|set]     代理端口模式设置
    tun      [on|off|status]       Tun 模式 (需要权限)
    lan      [on|off|status]       局域网访问控制
    mixin    [-e|-r]        Mixin 配置文件
    secret   [SECRET]       Web 控制台密钥
    subscribe [URL]         设置或查看订阅地址
    update   [auto|log]     更新订阅配置
    mihomo   [version|update] 管理 mihomo 内核

说明:
    • 用户空间运行，无需 sudo 权限
    • 配置目录: ~/tools/mihomo/
    • 日志目录: ~/tools/mihomo/logs/
    • 进程管理: 基于 PID 文件和 nohup

EOF
        ;;
    esac
}

function mihomoctl() {
    clashctl "$@"
}

function clash() {
    clashctl "$@"
}

function mihomo() {
    clashctl "$@"
}
