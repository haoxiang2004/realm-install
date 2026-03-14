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

# 自动注册全局快捷命令
if [ "$0" != "$PANEL_CMD" ]; then
    curl -sL "$REPO_URL" -o "$PANEL_CMD" 2>/dev/null || cp "$0" "$PANEL_CMD" 2>/dev/null
    chmod +x "$PANEL_CMD" 2>/dev/null
fi

# --- 基础依赖检测 ---
check_dependencies() {
    local pkgs=()
    command -v python3 &>/dev/null || pkgs+=("python3")
    command -v wget &>/dev/null || pkgs+=("wget")
    command -v curl &>/dev/null || pkgs+=("curl")
    command -v tar &>/dev/null || pkgs+=("tar")

    if [ ${#pkgs[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装基础依赖: ${pkgs[*]} ...${PLAIN}"
        apt-get update -yqq && apt-get install -yqq "${pkgs[@]}" 2>/dev/null || yum install -y "${pkgs[@]}" 2>/dev/null
    fi
}

# --- Python TOML 辅助模块 ---
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
    # 简单的正则匹配 endpoints 块
    blocks = re.split(r'\[\[endpoints\]\]', txt)[1:]
    for blk in blocks:
        l = re.search(r'listen\s*=\s*"([^"]+)"', blk)
        r = re.search(r'remote\s*=\s*"([^"]+)"', blk)
        if l and r: eps.append((l.group(1), r.group(1)))
    return eps

def write_eps(eps):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "w") as f:
        f.write("[network]\nno_tcp = false\nuse_udp = true\n\n")
        for l, r in eps:
            f.write(f"[[endpoints]]\nlisten = \"{l}\"\nremote = \"{r}\"\n\n")

if len(sys.argv) > 1:
    cmd = sys.argv[1]
    if cmd == "list":
        eps = read_eps()
        print("EMPTY" if not eps else "\n".join([f"{i+1}@@{l}@@{r}" for i, (l, r) in enumerate(eps)]))
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

# --- 核心管理逻辑 ---
install_realm() {
    echo -e "${YELLOW}>>> 准备安装/更新 Realm...${PLAIN}"
    local arch=$(uname -m)
    case "$arch" in
        x86_64) realm_arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) realm_arch="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}不支持的架构: $arch${PLAIN}"; return ;;
    esac

    local latest_ver=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$latest_ver" ]] && latest_ver="v2.6.0"
    
    local dl_url="https://github.com/zhboner/realm/releases/download/${latest_ver}/realm-${realm_arch}.tar.gz"
    echo -e "${CYAN}正在下载 Realm ${latest_ver}...${PLAIN}"
    wget -qO /tmp/realm.tar.gz "$dl_url" || { echo -e "${RED}下载失败${PLAIN}"; return; }
    
    systemctl stop realm 2>/dev/null
    tar -xzf /tmp/realm.tar.gz -C /tmp/ && mv /tmp/realm "$REALM_BIN" && chmod +x "$REALM_BIN"
    rm -f /tmp/realm.tar.gz

    mkdir -p "$CONFIG_DIR"
    [[ ! -f "$CONFIG_FILE" ]] && init_python_helper && python3 "$HELPER_PY" clear

    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Realm Service
After=network.target

[Service]
Type=simple
ExecStart=$REALM_BIN -c $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable realm && systemctl start realm
    echo -e "${GREEN}✅ Realm 安装成功并已启动！${PLAIN}"
    sleep 2
}

uninstall_realm() {
    echo -e "${RED}警告: 卸载将清空所有配置！${PLAIN}"
    read -p "确认卸载吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop realm && systemctl disable realm
        rm -rf "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_DIR" "$PANEL_CMD"
        echo -e "${GREEN}✅ 卸载完成。${PLAIN}"
        exit 0
    fi
}

add_rule() {
    echo -e "${CYAN}>>> 添加转发规则 (自动开启双栈监听)${PLAIN}"
    read -p "请输入本地监听端口: " lp
    [[ ! "$lp" =~ ^[0-9]+$ ]] && echo "无效端口" && return
    read -p "请输入目标地址 (域名/IP): " ra
    [[ -z "$ra" ]] && echo "地址不能为空" && return
    if [[ "$ra" =~ : && ! "$ra" =~ ^\[ ]]; then ra="[$ra]"; fi
    read -p "请输入目标端口: " rp
    [[ ! "$rp" =~ ^[0-9]+$ ]] && echo "无效端口" && return

    init_python_helper
    python3 "$HELPER_PY" add "[::]:$lp" "$ra:$rp"
    systemctl restart realm
    echo -e "${GREEN}✅ 规则已添加并生效！${PLAIN}"
    sleep 1
}

list_rules() {
    init_python_helper
    echo -e "\n${YELLOW}--- 当前转发规则 ---${PLAIN}"
    local res=$(python3 "$HELPER_PY" list)
    if [[ "$res" == "EMPTY" ]]; then
        echo "暂无转发规则。"
    else
        printf "%-6s | %-20s | %-30s\n" "序号" "本地监听" "远程目标"
        echo "------------------------------------------------------------"
        echo "$res" | while IFS="@@" read -r idx listen remote; do
            printf "${GREEN}%-4s${PLAIN} | ${YELLOW}%-18s${PLAIN} | ${CYAN}%-30s${PLAIN}\n" "[$idx]" "$listen" "$remote"
        done
    fi
}

delete_rule() {
    list_rules
    read -p "请输入要删除的规则序号 (回车取消): " idx
    [[ -z "$idx" ]] && return
    init_python_helper
    python3 "$HELPER_PY" del "$idx"
    systemctl restart realm
    echo -e "${GREEN}✅ 规则已删除！${PLAIN}"
    sleep 1
}

get_status() {
    if [[ ! -f "$REALM_BIN" ]]; then echo -e "${RED}未安装${PLAIN}"
    elif systemctl is-active --quiet realm; then echo -e "${GREEN}运行中${PLAIN}"
    else echo -e "${YELLOW}已停止${PLAIN}"; fi
}

# --- 主循环菜单 ---
main() {
    check_dependencies
    while true; do
        clear
        echo -e "
${CYAN}################################################${PLAIN}
${CYAN}#        Realm 专线中转面板 V${sh_ver}              #${PLAIN}
${CYAN}################################################${PLAIN}
 状态: $(get_status)
------------------------------------------------
 ${GREEN}1.${PLAIN} 安装 / 更新 Realm
 ${RED}2.${PLAIN} 彻底卸载 Realm
------------------------------------------------
 ${GREEN}3.${PLAIN} 添加转发规则
 ${GREEN}4.${PLAIN} 删除转发规则
 ${YELLOW}5.${PLAIN} 查看规则列表
------------------------------------------------
 ${CYAN}6.${PLAIN} 重启服务
 ${CYAN}7.${PLAIN} 查看运行日志
 ${PLAIN}0. 退出面板
------------------------------------------------"
        read -p "请选择: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_rule ;;
            4) delete_rule ;;
            5) list_rules; read -p "按回车返回..." ;;
            6) systemctl restart realm; echo "服务已重启"; sleep 1 ;;
            7) journalctl -u realm -n 30 --no-pager; read -p "按回车返回..." ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

main