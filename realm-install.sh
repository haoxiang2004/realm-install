#!/bin/bash

# ==========================================
# Realm 终极管理面板 (V1.0)
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
    if ! command -v python3 &> /dev/null; then pkgs+=("python3"); fi
    if ! command -v wget &> /dev/null; then pkgs+=("wget"); fi
    if ! command -v curl &> /dev/null; then pkgs+=("curl"); fi
    if ! command -v tar &> /dev/null; then pkgs+=("tar"); fi

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

# --- 核心管理逻辑 ---
install_realm() {
    local arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then local realm_arch="x86_64-unknown-linux-gnu"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then local realm_arch="aarch64-unknown-linux-gnu"
    else echo -e "${RED}不支持的架构: $arch${PLAIN}" && return; fi

    echo -e "${CYAN}正在获取最新版本...${PLAIN}"
    local latest_ver=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$latest_ver" ]] && latest_ver="v2.6.0"
    
    local dl_url="https://github.com/zhboner/realm/releases/download/${latest_ver}/realm-${realm_arch}.tar.gz"
    wget -qO /tmp/realm.tar.gz "$dl_url"
    systemctl stop realm 2>/dev/null
    tar -xzf /tmp/realm.tar.gz -C /tmp/ && mv /tmp/realm "$REALM_BIN" && chmod +x "$REALM_BIN"
    
    mkdir -p "$CONFIG_DIR"
    init_python_helper && python3 "$HELPER_PY" clear

    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Realm Service
After=network.target
[Service]
Type=simple
ExecStart=$REALM_BIN -c $CONFIG_FILE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable realm && systemctl start realm
    echo -e "${GREEN}Realm 安装成功！${PLAIN}"
}

uninstall_realm() {
    read -p "确定卸载吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop realm && systemctl disable realm
        rm -rf "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_DIR" "$PANEL_CMD"
        echo -e "${GREEN}卸载完成。${PLAIN}"
        exit 0
    fi
}

add_rule() {
    read -p "监听端口: " lp
    read -p "目标地址 (域名/IP): " ra
    if [[ "$ra" =~ : && ! "$ra" =~ ^\[ ]]; then ra="[$ra]"; fi
    read -p "目标端口: " rp
    init_python_helper
    python3 "$HELPER_PY" add "[::]:$lp" "$ra:$rp"
    systemctl restart realm
}

list_rules() {
    init_python_helper
    local res=$(python3 "$HELPER_PY" list)
    if [[ "$res" == "EMPTY" ]]; then echo "暂无规则"; else echo "$res" | tr '@@' ' '; fi
}

delete_rule() {
    list_rules
    read -p "要删除的序号: " idx
    init_python_helper
    python3 "$HELPER_PY" del "$idx"
    systemctl restart realm
}

# --- 主循环 ---
main() {
    check_dependencies
    while true; do
        clear
        echo -e "${CYAN}Realm 管理面板 V${sh_ver}${PLAIN}"
        echo -e "1. 安装/更新 2. 卸载\n3. 添加规则 4. 删除规则 5. 查看规则\n0. 退出"
        read -p "选择: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_rule ;;
            4) delete_rule ;;
            5) list_rules; read -p "回车继续..." ;;
            0) exit 0 ;;
        esac
    done
}

main