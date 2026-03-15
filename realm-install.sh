#!/bin/bash

# ==========================================
# Realm 终极管理面板 (V1.0.2 - 增强显示版)
# 描述: 专为 Realm 打造的自动化部署与 TUI 管理工具
# ==========================================

export LANG=en_US.UTF-8
sh_ver="1.0.2"

# --- 核心目录与文件 ---
CONFIG_DIR="/etc/realm"
TOML_FILE="${CONFIG_DIR}/config.toml"
RULE_FILE="${CONFIG_DIR}/rules.txt"  # 核心真理数据源
PANEL_CMD="/usr/local/bin/realm-panel"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
REPO_URL="https://raw.githubusercontent.com/haoxiang2004/realm-install/main/realm-install.sh"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行！${PLAIN}" && exit 1

# 自动注册全局命令
if [ "$0" != "$PANEL_CMD" ]; then
    curl -sL "$REPO_URL" -o "$PANEL_CMD" 2>/dev/null || cp "$0" "$PANEL_CMD" 2>/dev/null
    chmod +x "$PANEL_CMD" 2>/dev/null
fi

# --- 基础环境配置 ---
init_env() {
    mkdir -p "$CONFIG_DIR"
    touch "$RULE_FILE"
    
    # 兼容老版本的残留 TOML，避免冲突
    if [[ -f "$TOML_FILE" && ! -s "$RULE_FILE" ]]; then
        mv "$TOML_FILE" "${TOML_FILE}.bak" 2>/dev/null
    fi
}

# --- 核心引擎：从文本生成 TOML ---
generate_toml() {
    cat <<EOF > "$TOML_FILE"
[network]
no_tcp = false
use_udp = true

EOF
    
    if [[ -s "$RULE_FILE" ]]; then
        while read -r l_port r_addr r_port; do
            [[ -z "$l_port" || -z "$r_addr" || -z "$r_port" ]] && continue
            
            cat <<EOF >> "$TOML_FILE"
[[endpoints]]
listen = "[::]:${l_port}"
remote = "${r_addr}:${r_port}"

EOF
        done < "$RULE_FILE"
    fi
}

apply_config() {
    generate_toml
    if systemctl is-active --quiet realm; then
        systemctl restart realm
        echo -e "${GREEN}✅ 配置已生成，Realm 服务已热重启！${PLAIN}"
    else
        systemctl start realm
        echo -e "${GREEN}✅ 配置已生成，Realm 服务已拉起！${PLAIN}"
    fi
    sleep 1.5
}

# --- 功能模块 ---
install_realm() {
    echo -e "${YELLOW}>>> 开始安装/更新 Realm 核心组件...${PLAIN}"
    
    local arch=$(uname -m)
    case "$arch" in
        x86_64) realm_arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) realm_arch="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}严重错误: 不支持的系统架构 ${arch}${PLAIN}"; sleep 2; return ;;
    esac

    echo -e "${CYAN}正在请求 GitHub API 获取最新版本...${PLAIN}"
    local latest_ver=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$latest_ver" ]]; then
        latest_ver="v2.6.0"
        echo -e "${YELLOW}警告: 获取版本失败，将回退使用默认版本 ${latest_ver}${PLAIN}"
    fi
    
    local dl_url="https://github.com/zhboner/realm/releases/download/${latest_ver}/realm-${realm_arch}.tar.gz"
    echo -e "正在下载: ${GREEN}Realm ${latest_ver}${PLAIN}"
    
    wget -qO /tmp/realm.tar.gz "$dl_url"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查服务器网络连通性！${PLAIN}"
        sleep 2
        return
    fi

    systemctl stop realm 2>/dev/null
    tar -xzf /tmp/realm.tar.gz -C /tmp/
    mv /tmp/realm "$REALM_BIN"
    chmod +x "$REALM_BIN"
    rm -f /tmp/realm.tar.gz

    init_env
    generate_toml

    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Realm Port Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
ExecStart=$REALM_BIN -c $TOML_FILE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    systemctl start realm
    
    echo -e "${GREEN}✅ Realm ${latest_ver} 安装部署完毕！${PLAIN}"
    sleep 2
}

uninstall_realm() {
    echo -e "${RED}⚠️  警告: 此操作将彻底卸载 Realm 并清空所有转发规则！${PLAIN}"
    read -p "确定要继续吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop realm 2>/dev/null
        systemctl disable realm 2>/dev/null
        rm -rf "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_DIR" "$PANEL_CMD"
        systemctl daemon-reload
        echo -e "${GREEN}✅ Realm 及所有配置文件已从系统中彻底清除！再见！${PLAIN}"
        exit 0
    fi
}

add_rule() {
    [[ ! -f "$REALM_BIN" ]] && echo -e "${RED}请先安装 Realm 核心！${PLAIN}" && sleep 1.5 && return
    
    echo -e "${CYAN}>>> 添加新的转发规则${PLAIN}"
    echo -e "${YELLOW}提示: 底层将自动配置 [::] 双栈监听${PLAIN}"
    
    read -p "1. 本机监听端口 (如 10000): " l_port
    if [[ ! "$l_port" =~ ^[0-9]+$ ]] || [ "$l_port" -lt 1 ] || [ "$l_port" -gt 65535 ]; then
        echo -e "${RED}端口格式错误，必须为 1-65535 的数字！${PLAIN}"
        sleep 1.5; return
    fi
    
    if grep -q "^${l_port} " "$RULE_FILE" 2>/dev/null; then
        echo -e "${RED}错误: 本地监听端口 ${l_port} 已存在，请勿重复添加！${PLAIN}"
        sleep 1.5; return
    fi
    
    read -p "2. 目标地址 (域名 / IPv4 / IPv6): " r_addr
    [[ -z "$r_addr" ]] && echo -e "${RED}目标地址不能为空！${PLAIN}" && sleep 1.5 && return
    
    if [[ "$r_addr" =~ : && ! "$r_addr" =~ ^\[ ]]; then
        r_addr="[$r_addr]"
    fi
    
    read -p "3. 目标端口 (如 443): " r_port
    if [[ ! "$r_port" =~ ^[0-9]+$ ]] || [ "$r_port" -lt 1 ] || [ "$r_port" -gt 65535 ]; then
        echo -e "${RED}目标端口格式错误！${PLAIN}"
        sleep 1.5; return
    fi
    
    init_env
    echo "$l_port $r_addr $r_port" >> "$RULE_FILE"
    
    apply_config
}

list_rules() {
    [[ ! -f "$REALM_BIN" ]] && echo -e "${RED}请先安装 Realm 核心！${PLAIN}" && return
    init_env
    
    echo -e "\n${CYAN}======================== 当前转发规则列表 ========================${PLAIN}"
    if [[ ! -s "$RULE_FILE" ]]; then
        echo -e "${YELLOW}暂无任何转发规则。${PLAIN}"
    else
        printf "${GREEN}%-6s | %-15s | %-30s${PLAIN}\n" "序号" "本地监听端口" "目标地址:端口"
        echo "------------------------------------------------------------------"
        awk '{printf "[%-4s] | %-15s | %-30s\n", NR, $1, $2":"$3}' "$RULE_FILE"
    fi
    echo -e "${CYAN}==================================================================${PLAIN}"
    
    # === 新增：展示 TOML 原始配置内容 ===
    echo -e "\n${YELLOW}>>> config.toml 配置文件原始内容 <<<${PLAIN}"
    echo -e "------------------------------------------------------------------"
    if [[ -f "$TOML_FILE" ]]; then
        cat "$TOML_FILE"
    else
        echo -e "${RED}配置文件暂未生成。${PLAIN}"
    fi
    echo -e "------------------------------------------------------------------\n"
}

delete_rule() {
    list_rules
    [[ ! -s "$RULE_FILE" ]] && sleep 1.5 && return
    
    read -p "请输入要删除的规则【序号】 (直接回车取消): " idx
    [[ -z "$idx" ]] && return
    if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}请输入正确的数字序号！${PLAIN}"
        sleep 1.5; return
    fi
    
    local total_lines=$(wc -l < "$RULE_FILE")
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$total_lines" ]; then
        echo -e "${RED}序号不存在！${PLAIN}"
        sleep 1.5; return
    fi
    
    sed -i "${idx}d" "$RULE_FILE"
    echo -e "${GREEN}✅ 规则已删除！${PLAIN}"
    apply_config
}

clear_rules() {
    echo -e "${RED}⚠️  警告: 此操作将清空所有转发规则！${PLAIN}"
    read -p "确定要继续吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        > "$RULE_FILE"
        apply_config
        echo -e "${GREEN}✅ 所有规则已清空！${PLAIN}"
        sleep 1.5
    fi
}

show_menu() {
    clear
    local realm_version="未安装"
    local svc_status="${RED}■ 核心未安装${PLAIN}"
    local rule_count="0"
    
    if [[ -f "$REALM_BIN" ]]; then
        realm_version=$($REALM_BIN --version 2>/dev/null | awk '{print $2}')
        [[ -z "$realm_version" ]] && realm_version="未知版本"
        
        if systemctl is-active --quiet realm; then
            svc_status="${GREEN}▶ 正在运行${PLAIN}"
        else
            svc_status="${YELLOW}■ 已停止${PLAIN}"
        fi
        
        [[ -f "$RULE_FILE" ]] && rule_count=$(wc -l < "$RULE_FILE" 2>/dev/null || echo 0)
    fi

    echo -e "
${CYAN}#############################################################${PLAIN}
${CYAN}#               Realm 专线中转面板 (v${sh_ver})               #${PLAIN}
${CYAN}#############################################################${PLAIN}
 核心版本 : ${YELLOW}${realm_version}${PLAIN}
 运行状态 : ${svc_status}
 规则总数 : ${GREEN}${rule_count}${PLAIN} 条
-------------------------------------------------------------
 ${GREEN}1.${PLAIN} 安装 / 更新 Realm 核心
 ${RED}2.${PLAIN} 彻底卸载 Realm 面板
-------------------------------------------------------------
 ${GREEN}3.${PLAIN} 添加转发规则 (原生双栈支持)
 ${YELLOW}4.${PLAIN} 删除转发规则
 ${YELLOW}5.${PLAIN} 清空全部规则
 ${GREEN}6.${PLAIN} 查看规则列表与底层配置
-------------------------------------------------------------
 ${CYAN}7.${PLAIN} 启动 Realm 服务
 ${CYAN}8.${PLAIN} 停止 Realm 服务
 ${CYAN}9.${PLAIN} 重启 Realm 服务
 ${GREEN}10.${PLAIN}查看 Realm 运行日志
 ${GREEN}0.${PLAIN} 退出面板
${CYAN}#############################################################${PLAIN}"
}

main() {
    [[ ! -t 0 ]] && exec < /dev/tty
    
    while true; do
        show_menu
        read -p "请输入数字选择 [0-10]: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_rule ;;
            4) delete_rule ;;
            5) clear_rules ;;
            6) list_rules; read -p "按回车键返回主菜单..." ;;
            7) systemctl start realm; echo -e "${GREEN}服务已启动！${PLAIN}"; sleep 1 ;;
            8) systemctl stop realm; echo -e "${GREEN}服务已停止！${PLAIN}"; sleep 1 ;;
            9) systemctl restart realm; echo -e "${GREEN}服务已重启！${PLAIN}"; sleep 1 ;;
            10) 
               echo -e "${YELLOW}提示: 按 Ctrl+C 退出日志并返回主菜单。${PLAIN}"; sleep 1
               trap 'echo -e "\n${GREEN}已退出日志。${PLAIN}"' INT; journalctl -u realm -n 30 -f; trap - INT 
               ;;
            0) echo -e "${GREEN}退出成功。随时输入 realm-panel 重新唤出面板。${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}无效的选择！${PLAIN}"; sleep 1 ;;
        esac
    done
}

main