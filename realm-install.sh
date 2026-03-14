#!/bin/bash

# ==========================================
# Realm 终极管理面板 (V1.0)
# 描述: 专为 Realm 打造的自动化部署与 TUI 管理工具
# 仓库: https://github.com/haoxiang2004/realm-install
# ==========================================

sh_ver="1.0.0"
CONFIG_DIR="/etc/realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
PANEL_CMD="/usr/local/bin/realm-panel"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
HELPER_PY="/tmp/realm_helper.py"
REPO_URL="https://raw.githubusercontent.com/haoxiang2004/realm-install/main/realm-install.sh"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行！${PLAIN}" && exit 1

# 自动注册全局快捷命令与自更新
if [ "$0" != "$PANEL_CMD" ]; then
    curl -L "$REPO_URL" -o "$PANEL_CMD" 2>/dev/null || cp "$0" "$PANEL_CMD" 2>/dev/null
    chmod +x "$PANEL_CMD" 2>/dev/null
fi

# --- 基础依赖检测 ---
check_dependencies() {
    local pkgs=()
    if ! command -v python3 &> /dev/null; then pkgs+=("python3"); fi
    if ! command -v wget &> /dev/null; then pkgs+=("wget"); fi
    if ! command -v curl &> /dev/null; then pkgs+=("curl"); fi
    if ! command -v tar &> /dev/null; then pkgs+=("tar"); fi

    if [ ${#pkgs[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装基础依赖: ${pkgs[*]} ...${PLAIN}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -yqq && apt-get install -yqq "${pkgs[@]}" 2>/dev/null || yum install -y "${pkgs[@]}" 2>/dev/null
    fi
}

# --- Python TOML 辅助模块 (动态生成) ---
init_python_helper() {
    cat << 'EOF' > "$HELPER_PY"
import sys, re, os
CONF = "/etc/realm/config.toml"

def read_eps():
    if not os.path.exists(CONF): return []
    try:
        with open(CONF, "r") as f: txt = f.read()
    except: return []
    eps = []
    for blk in txt.split("[[endpoints]]")[1:]:
        l = re.search(r'listen\s*=\s*"([^"]+)"', blk)
        r = re.search(r'remote\s*=\s*"([^"]+)"', blk)
        if l and r: eps.append((l.group(1), r.group(1)))
    return eps

def write_eps(eps):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "w") as f:
        f.write("[network]\nno_tcp = false\nuse_udp = true\n\n")
        for l, r in eps: f.write(f"[[endpoints]]\nlisten = \"{l}\"\nremote = \"{r}\"\n\n")

if len(sys.argv) > 1:
    cmd = sys.argv[1]
    if cmd == "list":
        eps = read_eps()
        if not eps: print("EMPTY")
        for i, (l, r) in enumerate(eps): print(f"{i+1}@@{l}@@{r}")
    elif cmd == "add":
        eps = read_eps()
        eps.append((sys.argv[2], sys.argv[3]))
        write_eps(eps)
    elif cmd == "del":
        eps = read_eps()
        idx = int(sys.argv[2]) - 1
        if 0 <= idx < len(eps): eps.pop(idx); write_eps(eps)
    elif cmd == "clear": write_eps([])
EOF
}

# --- 核心组件管理 ---

install_realm() {
    echo -e "${YELLOW}>>> 开始从 GitHub 获取 Realm 核心组件...${PLAIN}"
    
    local arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        local realm_arch="x86_64-unknown-linux-gnu"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        local realm_arch="aarch64-unknown-linux-gnu"
    else
        echo -e "${RED}不支持的系统架构: $arch${PLAIN}" && sleep 2 && return
    fi

    echo -e "${CYAN}正在探测最新版本...${PLAIN}"
    local latest_ver=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$latest_ver" ]] && latest_ver="v2.6.0" && echo -e "${YELLOW}API 请求受限，回退到默认版本: $latest_ver${PLAIN}"
    
    local dl_url="https://github.com/zhboner/realm/releases/download/${latest_ver}/realm-${realm_arch}.tar.gz"
    echo -e "正在下载: ${GREEN}$dl_url${PLAIN}"
    
    wget -qO /tmp/realm.tar.gz "$dl_url"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查服务器网络！${PLAIN}" && sleep 2 && return
    fi

    systemctl stop realm 2>/dev/null
    tar -xzf /tmp/realm.tar.gz -C /tmp/
    mv /tmp/realm "$REALM_BIN"
    chmod +x "$REALM_BIN"
    rm -f /tmp/realm.tar.gz

    # 初始化配置
    mkdir -p "$CONFIG_DIR"
    [[ ! -f "$CONFIG_FILE" ]] && init_python_helper && python3 "$HELPER_PY" clear

    # 注册 Systemd
    cat << 'EOF' > "$SERVICE_FILE"
[Unit]
Description=Realm Port Forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    systemctl start realm
    
    echo -e "${GREEN}✅ Realm ${latest_ver} 安装并启动成功！${PLAIN}"
    sleep 2
}

uninstall_realm() {
    echo -e "${YELLOW}>>> 危险操作：彻底卸载 Realm${PLAIN}"
    read -p "确定要彻底卸载 Realm 并清空所有转发规则吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop realm 2>/dev/null
        systemctl disable realm 2>/dev/null
        rm -rf "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_DIR"
        systemctl daemon-reload
        echo -e "${GREEN}✅ Realm 及所有配置文件已彻底清除！${PLAIN}"
        
        read -p "是否顺便卸载本管理面板 (realm-panel)? (y/n): " rm_panel
        if [[ "$rm_panel" == "y" || "$rm_panel" == "Y" ]]; then
            rm -f "$PANEL_CMD" "$HELPER_PY"
            echo -e "${GREEN}面板已卸载。再见！${PLAIN}"
            exit 0
        fi
    else
        echo -e "${GREEN}已取消卸载。${PLAIN}"
    fi
    sleep 1.5
}

# --- 规则业务逻辑 ---

apply_config() {
    systemctl restart realm
    echo -e "${GREEN}✅ 规则已更新，服务已重启生效！${PLAIN}"
    sleep 1.5
}

add_rule() {
    [[ ! -f "$REALM_BIN" ]] && echo -e "${RED}请先在主菜单按 1 安装 Realm 核心！${PLAIN}" && sleep 2 && return
    echo -e "${YELLOW}>>> 添加 Realm 转发规则${PLAIN}"
    
    read -p "1. 本机监听端口 (如 10000): " l_port
    [[ ! "$l_port" =~ ^[0-9]+$ ]] && echo -e "${RED}端口格式错误！${PLAIN}" && sleep 1 && return
    local listen_addr="[::]:$l_port" # 自动双栈监听
    
    read -p "2. 目标域名或 IP (支持IPv6): " r_addr
    [[ -z "$r_addr" ]] && echo -e "${RED}地址不能为空！${PLAIN}" && sleep 1 && return
    if [[ "$r_addr" =~ : ]]; then [[ ! "$r_addr" =~ ^\[.*\]$ ]] && r_addr="[$r_addr]"; fi
    
    read -p "3. 目标端口 (如 443): " r_port
    [[ ! "$r_port" =~ ^[0-9]+$ ]] && echo -e "${RED}端口格式错误！${PLAIN}" && sleep 1 && return
    
    init_python_helper
    python3 "$HELPER_PY" add "$listen_addr" "$r_addr:$r_port"
    apply_config
}

list_rules() {
    [[ ! -f "$REALM_BIN" ]] && echo -e "${RED}未检测到 Realm，请先安装！${PLAIN}" && return
    init_python_helper
    echo -e "\n${CYAN}--- 当前 Realm 转发规则列表 ---${PLAIN}"
    printf "%-6s | %-20s | %-30s\n" "序号" "监听地址 (本地双栈)" "转发目标 (远程)"
    echo -e "------------------------------------------------------------"
    local res=$(python3 "$HELPER_PY" list)
    if [[ "$res" == "EMPTY" ]]; then
        echo -e "暂无任何转发规则。"
    else
        echo "$res" | while IFS="@@" read -r idx listen remote; do
            printf "${GREEN}%-4s${PLAIN} | ${YELLOW}%-18s${PLAIN} | ${CYAN}%-30s${PLAIN}\n" "[$idx]" "$listen" "$remote"
        done
    fi
    echo -e "------------------------------------------------------------"
}

delete_rule() {
    list_rules
    read -p "请输入要删除的规则序号 (0 取消): " idx
    [[ "$idx" == "0" || -z "$idx" || ! "$idx" =~ ^[0-9]+$ ]] && return
    init_python_helper; python3 "$HELPER_PY" del "$idx"; apply_config
}

clear_rules() {
    read -p "⚠️ 确定要清空所有转发规则吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        init_python_helper; python3 "$HELPER_PY" clear; apply_config
    fi
}

get_status() {
    if [[ ! -f "$REALM_BIN" ]]; then
        echo -e "${RED}■ 未安装${PLAIN}"
    elif systemctl is-active --quiet realm; then
        echo -e "${GREEN}▶ 运行中 (Running)${PLAIN}"
    else
        echo -e "${YELLOW}■ 已停止 (Stopped)${PLAIN}"
    fi
}

# --- 界面交互 ---
show_menu() {
    clear
    echo -e "
${CYAN}################################################${PLAIN}
${CYAN}#        Realm 专线中转面板 (v${sh_ver})           #${PLAIN}
${CYAN}################################################${PLAIN}
 核心状态: $(get_status)
------------------------------------------------
 ${GREEN}1.${PLAIN} 安装 / 更新 Realm 核心组件
 ${RED}2.${PLAIN} 彻底卸载 Realm 及管理面板
------------------------------------------------
 ${GREEN}3.${PLAIN} 添加转发规则 (自带 IPv4/v6 双栈监听)
 ${GREEN}4.${PLAIN} 删除转发规则
 ${YELLOW}5.${PLAIN} 清空全部规则
 ${GREEN}6.${PLAIN} 查看当前规则
------------------------------------------------
 ${CYAN}7.${PLAIN} 启动 Realm 服务
 ${CYAN}8.${PLAIN} 停止 Realm 服务
 ${CYAN}9.${PLAIN} 重启 Realm 服务
 ${GREEN}10.${PLAIN}查看 Realm 运行日志
 ${GREEN}0.${PLAIN} 退出面板
${CYAN}################################################${PLAIN}"
}

main() {
    check_dependencies
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
            6) list_rules; read -p "按回车键返回..." ;;
            7) systemctl start realm; echo -e "${GREEN}已启动！${PLAIN}"; sleep 1 ;;
            8) systemctl stop realm; echo -e "${GREEN}已停止！${PLAIN}"; sleep 1 ;;
            9) systemctl restart realm; echo -e "${GREEN}已重启！${PLAIN}"; sleep 1 ;;
            10) 
               echo -e "${YELLOW}提示: 按 Ctrl+C 退出日志并返回主菜单。${PLAIN}"; sleep 1
               trap 'echo -e "\n${GREEN}已退出。${PLAIN}"' INT; journalctl -u realm -n 30 -f; trap - INT 
               ;;
            0) echo -e "${GREEN}退出成功。随时输入 realm-panel 重新进入。${PLAIN}"; rm -f "$HELPER_PY"; exit 0 ;;
            *) echo -e "${RED}无效的选择！${PLAIN}"; sleep 1 ;;
        esac
    done
}

main
