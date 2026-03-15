#!/bin/bash

# ==========================================
# Realm 终极管理面板 (V2.0 - Web 增强版)
# 描述: 专为 Realm 打造的 TUI + Web 自动化管理工具
# ==========================================

export LANG=en_US.UTF-8
sh_ver="2.0.0"

# --- 核心目录与文件 ---
CONFIG_DIR="/etc/realm"
TOML_FILE="${CONFIG_DIR}/config.toml"
RULE_FILE="${CONFIG_DIR}/rules.txt"
PANEL_CMD="/usr/local/bin/realm-panel"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"

WEB_PY="/usr/local/bin/realm-web.py"
WEB_SERVICE="/etc/systemd/system/realm-web.service"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行！${PLAIN}" && exit 1

# --- Web UI 的 API 通信接口 (后台静默执行) ---
if [[ "$1" == "sync" ]]; then
    # 生成 TOML
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
    systemctl restart realm
    exit 0
fi

# 自动注册全局命令
if [ "$0" != "$PANEL_CMD" ]; then
    cp "$0" "$PANEL_CMD" 2>/dev/null
    chmod +x "$PANEL_CMD" 2>/dev/null
fi

init_env() {
    mkdir -p "$CONFIG_DIR"
    touch "$RULE_FILE"
}

apply_config() {
    "$PANEL_CMD" sync
    echo -e "${GREEN}✅ 配置已生成，Realm 服务已热重启生效！${PLAIN}"
    sleep 1.5
}

# --- Web 面板管理模块 ---
install_web() {
    echo -e "${CYAN}>>> 部署 Realm Web 管理面板${PLAIN}"
    
    read -p "1. 请设置 Web 访问端口 (默认 8080): " web_port
    [[ -z "$web_port" ]] && web_port=8080
    
    read -p "2. 请设置登录用户名 (默认 admin): " web_user
    [[ -z "$web_user" ]] && web_user="admin"
    
    read -p "3. 请设置登录密码: " web_pass
    [[ -z "$web_pass" ]] && echo -e "${RED}密码不能为空！${PLAIN}" && sleep 1.5 && return

    # 写入动态变量
    cat << EOF > "$WEB_PY"
PORT = $web_port
USER = "$web_user"
PASS = "$web_pass"
EOF

    # 写入 Python 原生 Web 服务器逻辑 (禁止变量展开)
    cat << 'EOF' >> "$WEB_PY"
import http.server, socketserver, base64, json, os, subprocess

KEY = base64.b64encode(f"{USER}:{PASS}".encode('utf-8')).decode('ascii')
RULE_FILE = '/etc/realm/rules.txt'

HTML = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Realm Web 面板</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style> body { background-color: #f8f9fa; } .card { box-shadow: 0 4px 6px rgba(0,0,0,0.1); border: none; } </style>
</head>
<body>
<div class="container mt-5">
    <div class="d-flex justify-content-between align-items-center mb-4">
        <h2 class="fw-bold text-primary">🚀 Realm 转发管理系统</h2>
        <span id="statusBadge" class="badge bg-secondary fs-6">状态检测中...</span>
    </div>
    
    <div class="card mb-4">
        <div class="card-body">
            <h5 class="card-title fw-bold">➕ 添加新规则 (自动双栈)</h5>
            <div class="row g-2 mt-2">
                <div class="col-md-3"><input type="number" id="lPort" class="form-control" placeholder="本地监听端口 (如 10000)"></div>
                <div class="col-md-5"><input type="text" id="rAddr" class="form-control" placeholder="目标地址 (域名/IPv4/IPv6)"></div>
                <div class="col-md-3"><input type="number" id="rPort" class="form-control" placeholder="目标端口 (如 443)"></div>
                <div class="col-md-1"><button class="btn btn-primary w-100" onclick="addRule()">添加</button></div>
            </div>
        </div>
    </div>

    <div class="card">
        <div class="card-body">
            <h5 class="card-title fw-bold mb-3">📋 当前转发列表</h5>
            <div class="table-responsive">
                <table class="table table-hover align-middle">
                    <thead class="table-light"><tr><th>序号</th><th>监听端口 (本地)</th><th>目标地址:端口 (远程)</th><th>操作</th></tr></thead>
                    <tbody id="ruleTable"><tr><td colspan="4" class="text-center">加载中...</td></tr></tbody>
                </table>
            </div>
        </div>
    </div>
</div>

<script>
    async function loadData() {
        const res = await fetch('/api/list'); const rules = await res.json();
        let html = '';
        rules.forEach((r, i) => {
            html += `<tr><td>${i+1}</td><td><span class="badge bg-success">[::]:${r.l}</span></td>
                     <td class="text-primary fw-bold">${r.ra}:${r.rp}</td>
                     <td><button class="btn btn-sm btn-danger" onclick="delRule(${i+1})">删除</button></td></tr>`;
        });
        document.getElementById('ruleTable').innerHTML = html || '<tr><td colspan="4" class="text-center">暂无规则</td></tr>';
        
        const stRes = await fetch('/api/status'); const st = await stRes.json();
        const badge = document.getElementById('statusBadge');
        if(st.active) { badge.className = 'badge bg-success fs-6'; badge.innerText = '▶ Realm 运行中'; }
        else { badge.className = 'badge bg-danger fs-6'; badge.innerText = '■ Realm 已停止'; }
    }
    
    async function addRule() {
        const l = document.getElementById('lPort').value, ra = document.getElementById('rAddr').value, rp = document.getElementById('rPort').value;
        if(!l || !ra || !rp) return alert('请填写完整信息！');
        await fetch('/api/add', { method: 'POST', body: JSON.stringify({l, ra, rp}) });
        document.getElementById('lPort').value = ''; document.getElementById('rAddr').value = ''; document.getElementById('rPort').value = '';
        loadData();
    }
    
    async function delRule(id) {
        if(!confirm('确定删除该规则吗？')) return;
        await fetch('/api/del', { method: 'POST', body: JSON.stringify({id}) });
        loadData();
    }
    window.onload = loadData;
</script>
</body>
</html>
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def check_auth(self):
        if self.headers.get('Authorization') == f"Basic {KEY}": return True
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Realm Web UI"')
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        self.wfile.write(b"401 Unauthorized")
        return False

    def do_GET(self):
        if not self.check_auth(): return
        if self.path == '/':
            self.send_response(200); self.send_header('Content-type', 'text/html; charset=utf-8'); self.end_headers()
            self.wfile.write(HTML.encode('utf-8'))
        elif self.path == '/api/list':
            self.send_response(200); self.send_header('Content-type', 'application/json'); self.end_headers()
            rules = []
            if os.path.exists(RULE_FILE):
                with open(RULE_FILE, 'r') as f:
                    for line in f:
                        p = line.strip().split()
                        if len(p) >= 3: rules.append({"l": p[0], "ra": p[1], "rp": p[2]})
            self.wfile.write(json.dumps(rules).encode('utf-8'))
        elif self.path == '/api/status':
            self.send_response(200); self.send_header('Content-type', 'application/json'); self.end_headers()
            is_active = False
            try:
                res = subprocess.run(['systemctl', 'is-active', 'realm'], capture_output=True, text=True)
                if "active" in res.stdout: is_active = True
            except: pass
            self.wfile.write(json.dumps({"active": is_active}).encode('utf-8'))

    def do_POST(self):
        if not self.check_auth(): return
        cl = int(self.headers.get('Content-Length', 0))
        data = json.loads(self.rfile.read(cl).decode('utf-8'))
        
        if self.path == '/api/add':
            ra = data['ra']
            if ':' in ra and not ra.startswith('['): ra = f"[{ra}]"
            with open(RULE_FILE, 'a') as f: f.write(f"{data['l']} {ra} {data['rp']}\n")
            subprocess.run(['/usr/local/bin/realm-panel', 'sync'])
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
            
        elif self.path == '/api/del':
            idx = int(data['id'])
            if os.path.exists(RULE_FILE):
                with open(RULE_FILE, 'r') as f: lines = f.readlines()
                if 0 < idx <= len(lines):
                    del lines[idx-1]
                    with open(RULE_FILE, 'w') as f: f.writelines(lines)
            subprocess.run(['/usr/local/bin/realm-panel', 'sync'])
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')

with socketserver.ThreadingTCPServer(("", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF

    cat << EOF > "$WEB_SERVICE"
[Unit]
Description=Realm Web Dashboard
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $WEB_PY
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable realm-web >/dev/null 2>&1
    systemctl restart realm-web
    
    local public_ip=$(curl -s ifconfig.me)
    echo -e "${GREEN}✅ Web 面板安装成功并已启动！${PLAIN}"
    echo -e "访问地址: ${CYAN}http://${public_ip}:${web_port}${PLAIN}"
    echo -e "用户: ${YELLOW}${web_user}${PLAIN} | 密码: ${YELLOW}${web_pass}${PLAIN}"
    echo -e "请确保服务器安全组/防火墙已放行 TCP ${web_port} 端口。"
    sleep 4
}

uninstall_web() {
    systemctl stop realm-web 2>/dev/null
    systemctl disable realm-web 2>/dev/null
    rm -f "$WEB_PY" "$WEB_SERVICE"
    systemctl daemon-reload
    echo -e "${GREEN}✅ Web 面板已卸载（不会影响底层 Realm 转发）。${PLAIN}"
    sleep 1.5
}

# --- 核心 Realm 逻辑 ---
install_realm() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) realm_arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) realm_arch="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}不支持的架构: $arch${PLAIN}"; sleep 2; return ;;
    esac

    local latest_ver=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$latest_ver" ]] && latest_ver="v2.6.0"
    
    local dl_url="https://github.com/zhboner/realm/releases/download/${latest_ver}/realm-${realm_arch}.tar.gz"
    echo -e "正在下载: ${GREEN}Realm ${latest_ver}${PLAIN}"
    wget -qO /tmp/realm.tar.gz "$dl_url" || { echo -e "${RED}下载失败${PLAIN}"; sleep 2; return; }
    
    systemctl stop realm 2>/dev/null
    tar -xzf /tmp/realm.tar.gz -C /tmp/ && mv /tmp/realm "$REALM_BIN" && chmod +x "$REALM_BIN"
    rm -f /tmp/realm.tar.gz

    init_env
    "$PANEL_CMD" sync

    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Realm Port Forwarding Service
After=network-online.target
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

    systemctl daemon-reload && systemctl enable realm >/dev/null 2>&1
    systemctl start realm
    echo -e "${GREEN}✅ Realm 安装成功！${PLAIN}"
    sleep 1.5
}

uninstall_realm() {
    read -p "危险：确定要卸载 Realm 并清空规则吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop realm; systemctl disable realm
        uninstall_web
        rm -rf "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_DIR" "$PANEL_CMD"
        echo -e "${GREEN}✅ 彻底卸载完毕！${PLAIN}"; exit 0
    fi
}

add_rule() {
    read -p "1. 本机监听端口: " l_port
    [[ ! "$l_port" =~ ^[0-9]+$ ]] && return
    read -p "2. 目标地址 (域名/IP): " r_addr
    [[ -z "$r_addr" ]] && return
    if [[ "$r_addr" =~ : && ! "$r_addr" =~ ^\[ ]]; then r_addr="[$r_addr]"; fi
    read -p "3. 目标端口: " r_port
    [[ ! "$r_port" =~ ^[0-9]+$ ]] && return

    init_env
    echo "$l_port $r_addr $r_port" >> "$RULE_FILE"
    apply_config
}

list_rules() {
    init_env
    echo -e "\n${CYAN}======================== 当前转发规则列表 ========================${PLAIN}"
    if [[ ! -s "$RULE_FILE" ]]; then echo -e "${YELLOW}暂无任何转发规则。${PLAIN}"
    else awk '{printf "[%-4s] | %-15s | %-30s\n", NR, $1, $2":"$3}' "$RULE_FILE"; fi
    
    echo -e "\n${YELLOW}>>> config.toml 配置文件原始内容 <<<${PLAIN}"
    [[ -f "$TOML_FILE" ]] && cat "$TOML_FILE" || echo "未生成"
}

delete_rule() {
    list_rules
    read -p "请输入要删除的序号 (直接回车取消): " idx
    [[ -z "$idx" || ! "$idx" =~ ^[0-9]+$ ]] && return
    sed -i "${idx}d" "$RULE_FILE"
    apply_config
}

get_status() {
    if [[ ! -f "$REALM_BIN" ]]; then echo -e "${RED}未安装${PLAIN}"
    elif systemctl is-active --quiet realm; then echo -e "${GREEN}运行中${PLAIN}"
    else echo -e "${YELLOW}已停止${PLAIN}"; fi
}

get_web_status() {
    if systemctl is-active --quiet realm-web; then echo -e "${GREEN}运行中${PLAIN}"
    else echo -e "${YELLOW}未安装 / 已停止${PLAIN}"; fi
}

# --- 菜单 UI ---
main() {
    [[ ! -t 0 ]] && exec < /dev/tty
    while true; do
        clear
        local rule_count="0"
        [[ -f "$RULE_FILE" ]] && rule_count=$(wc -l < "$RULE_FILE" 2>/dev/null || echo 0)
        
        echo -e "
${CYAN}#############################################################${PLAIN}
${CYAN}#               Realm 专线中转面板 (v${sh_ver})               #${PLAIN}
${CYAN}#############################################################${PLAIN}
 转发核心 : $(get_status)    |   规则总数 : ${GREEN}${rule_count}${PLAIN}
 Web 面板 : $(get_web_status)
-------------------------------------------------------------
 ${GREEN}1.${PLAIN} 安装 / 更新 Realm 核心
 ${RED}2.${PLAIN} 彻底卸载 Realm 面板
-------------------------------------------------------------
 ${GREEN}3.${PLAIN} 添加转发规则 (原生双栈支持)
 ${YELLOW}4.${PLAIN} 删除转发规则
 ${GREEN}5.${PLAIN} 查看规则列表与底层配置
-------------------------------------------------------------
 ${CYAN}6.${PLAIN} 安装 / 重置 Web 管理面板 ${YELLOW}(带密码验证)${PLAIN}
 ${CYAN}7.${PLAIN} 停止 / 卸载 Web 面板
-------------------------------------------------------------
 ${CYAN}8.${PLAIN} 重启 Realm 服务
 ${GREEN}9.${PLAIN} 查看 Realm 运行日志
 ${GREEN}0.${PLAIN} 退出终端面板
${CYAN}#############################################################${PLAIN}"
        read -p "请选择操作 [0-9]: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_rule ;;
            4) delete_rule ;;
            5) list_rules; read -p "按回车键返回..." ;;
            6) install_web ;;
            7) uninstall_web ;;
            8) systemctl restart realm; echo -e "${GREEN}服务已重启！${PLAIN}"; sleep 1 ;;
            9) journalctl -u realm -n 30 -f; read -p "按回车键返回..." ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

main