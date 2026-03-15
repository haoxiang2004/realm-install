#!/bin/bash

# ==========================================
# Realm 智控面板 V3.2 (双控配置完全体)
# 描述: 终端 11 项全功能 + Web 在线改端口/密码
# ==========================================

export LANG=en_US.UTF-8
sh_ver="3.2.0"

# --- 核心目录与文件 ---
CONFIG_DIR="/etc/realm"
TOML_FILE="${CONFIG_DIR}/config.toml"
RULE_FILE="${CONFIG_DIR}/rules.txt"
WEB_CONF="${CONFIG_DIR}/web.conf"

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

# --- 加载或初始化 Web 配置 ---
if [[ -f "$WEB_CONF" ]]; then
    source "$WEB_CONF"
else
    WEB_PORT=8081
    WEB_PASS="123456"
    mkdir -p "$CONFIG_DIR"
    echo "WEB_PORT=$WEB_PORT" > "$WEB_CONF"
    echo "WEB_PASS=\"$WEB_PASS\"" >> "$WEB_CONF"
fi

# ==========================================
# 核心功能模块 (供 API 和命令行调用)
# ==========================================

sync_realm() {
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
}

install_web() {
    cat << EOF > "$WEB_PY"
PORT = $WEB_PORT
PASS = "$WEB_PASS"
EOF

    cat << 'EOF' >> "$WEB_PY"
import http.server, socketserver, json, os, subprocess, hashlib

TOKEN = hashlib.sha256(PASS.encode()).hexdigest()
RULE_FILE = '/etc/realm/rules.txt'
CONF_FILE = '/etc/realm/config.toml'

LOGIN_HTML = """
<!DOCTYPE html><html lang="zh-CN"><head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Realm 登录</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); height: 100vh; display: flex; align-items: center; justify-content: center; }
        .card { border-radius: 15px; box-shadow: 0 15px 35px rgba(0,0,0,0.2); border: none; padding: 2rem; width: 100%; max-width: 400px; background: rgba(255,255,255,0.95); }
    </style>
</head><body>
    <div class="card">
        <h3 class="text-center mb-4 fw-bold" style="color: #4a4a4a;">🚀 Realm 控制台</h3>
        <input type="password" id="pwd" class="form-control mb-3 form-control-lg" placeholder="请输入管理密码" onkeydown="if(event.keyCode==13) login()">
        <button class="btn btn-primary w-100 fw-bold btn-lg" onclick="login()" style="background: #667eea; border: none;">登 录</button>
        <p id="err" class="text-danger mt-3 text-center" style="display:none; font-weight:bold;">❌ 密码错误</p>
    </div>
    <script>
        async function login() {
            const p = document.getElementById('pwd').value;
            const r = await fetch('/api/login', {method:'POST', body: JSON.stringify({pass: p})});
            if(r.ok) window.location.reload(); else document.getElementById('err').style.display='block';
        }
    </script>
</body></html>
"""

DASHBOARD_HTML = """
<!DOCTYPE html><html lang="zh-CN"><head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Realm Web 管理</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style> body { background-color: #f4f6f9; } .card { box-shadow: 0 4px 12px rgba(0,0,0,0.05); border: none; border-radius: 10px; margin-bottom: 20px; } pre { background: #2d2d2d; color: #ccc; padding: 15px; border-radius: 8px; } </style>
</head><body>
<nav class="navbar navbar-dark bg-dark mb-4 shadow-sm">
    <div class="container d-flex justify-content-between">
        <span class="navbar-brand fw-bold">🚀 Realm 智控中心</span>
        <div>
            <button class="btn btn-outline-info btn-sm me-2" onclick="showModal('settingModal')">⚙️ 面板设置</button>
            <button class="btn btn-outline-light btn-sm" onclick="logout()">安全退出</button>
        </div>
    </div>
</nav>
<div class="container">
    <div class="card"><div class="card-body">
        <div class="d-flex justify-content-between align-items-center flex-wrap">
            <div><h5 class="fw-bold mb-0">系统状态: <span id="statusBadge" class="badge bg-secondary">检测中...</span></h5></div>
            <div class="mt-2 mt-md-0">
                <button class="btn btn-warning fw-bold text-dark me-2" onclick="apiAction('/api/restart', 'Realm 服务已重启生效！')">🔄 重启 Realm</button>
                <button class="btn btn-info fw-bold text-white me-2" onclick="showModal('configModal')">📄 查看配置</button>
                <button class="btn btn-secondary fw-bold" onclick="showModal('logModal')">📝 运行日志</button>
            </div>
        </div>
    </div></div>

    <div class="card"><div class="card-body">
        <h5 class="card-title fw-bold">➕ 添加转发 (自带双栈)</h5>
        <div class="row g-2 mt-2">
            <div class="col-md-3"><input type="number" id="lPort" class="form-control" placeholder="本地端口 (例: 10000)"></div>
            <div class="col-md-5"><input type="text" id="rAddr" class="form-control" placeholder="目标地址 (域名/IPv4/IPv6)"></div>
            <div class="col-md-3"><input type="number" id="rPort" class="form-control" placeholder="目标端口 (例: 443)"></div>
            <div class="col-md-1"><button class="btn btn-success w-100 fw-bold" onclick="addRule()">添加</button></div>
        </div>
    </div></div>

    <div class="card"><div class="card-body">
        <h5 class="card-title fw-bold mb-3">📋 转发规则列表</h5>
        <div class="table-responsive">
            <table class="table table-hover align-middle text-center">
                <thead class="table-light"><tr><th>ID</th><th>本地监听</th><th>远程目标</th><th>操作</th></tr></thead>
                <tbody id="ruleTable"><tr><td colspan="4">加载中...</td></tr></tbody>
            </table>
        </div>
    </div></div>
</div>

<div class="modal fade" id="settingModal" tabindex="-1"><div class="modal-dialog"><div class="modal-content">
    <div class="modal-header"><h5 class="modal-title fw-bold">⚙️ Web 面板设置</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
    <div class="modal-body">
        <div class="mb-3"><label class="form-label fw-bold">新 Web 端口</label><input type="number" id="newWebPort" class="form-control" placeholder="留空则不修改"></div>
        <div class="mb-3"><label class="form-label fw-bold">新登录密码</label><input type="text" id="newWebPass" class="form-control" placeholder="留空则不修改"></div>
    </div>
    <div class="modal-footer"><button class="btn btn-primary fw-bold" onclick="updateWeb()">保存并重启 Web</button></div>
</div></div></div>

<div class="modal fade" id="configModal" tabindex="-1"><div class="modal-dialog modal-lg"><div class="modal-content">
    <div class="modal-header"><h5 class="modal-title fw-bold">📄 config.toml 源码</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
    <div class="modal-body"><pre id="configContent">加载中...</pre></div>
</div></div></div>
<div class="modal fade" id="logModal" tabindex="-1"><div class="modal-dialog modal-lg"><div class="modal-content">
    <div class="modal-header"><h5 class="modal-title fw-bold">📝 Realm 最新运行日志</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
    <div class="modal-body"><pre id="logContent">加载中...</pre></div>
</div></div></div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
    async function fetchApi(url, options={}) {
        const res = await fetch(url, options);
        if(res.status === 401) window.location.reload();
        return res;
    }
    async function loadData() {
        const stRes = await fetchApi('/api/status'); const st = await stRes.json();
        const b = document.getElementById('statusBadge');
        if(st.active){ b.className='badge bg-success'; b.innerText='▶ 运行中'; }else{ b.className='badge bg-danger'; b.innerText='■ 已停止'; }
        
        const res = await fetchApi('/api/list'); const rules = await res.json();
        let html = '';
        rules.forEach((r, i) => {
            html += `<tr><td>${i+1}</td><td><span class="badge bg-primary fs-6">[::]:${r.l}</span></td>
                     <td class="fw-bold" style="color:#e83e8c;">${r.ra}:${r.rp}</td>
                     <td><button class="btn btn-sm btn-danger fw-bold" onclick="delRule(${i+1})">删除</button></td></tr>`;
        });
        document.getElementById('ruleTable').innerHTML = html || '<tr><td colspan="4" class="text-muted">暂无任何规则</td></tr>';
    }
    async function addRule() {
        const l = document.getElementById('lPort').value, ra = document.getElementById('rAddr').value, rp = document.getElementById('rPort').value;
        if(!l || !ra || !rp) return alert('参数不完整！');
        await fetchApi('/api/add', {method:'POST', body:JSON.stringify({l,ra,rp})});
        document.getElementById('lPort').value=''; document.getElementById('rAddr').value=''; document.getElementById('rPort').value='';
        loadData();
    }
    async function delRule(id) {
        if(!confirm('确定删除？')) return;
        await fetchApi('/api/del', {method:'POST', body:JSON.stringify({id})}); loadData();
    }
    async function apiAction(url, msg) {
        await fetchApi(url, {method:'POST'}); alert(msg); loadData();
    }
    async function showModal(id) {
        if(id === 'configModal'){
            const r = await fetchApi('/api/config'); const txt = await r.text();
            document.getElementById('configContent').innerText = txt;
        } else if(id === 'logModal'){
            const r = await fetchApi('/api/logs'); const txt = await r.text();
            document.getElementById('logContent').innerText = txt;
        }
        new bootstrap.Modal(document.getElementById(id)).show();
    }
    async function updateWeb() {
        const port = document.getElementById('newWebPort').value;
        const pwd = document.getElementById('newWebPass').value;
        if(!port && !pwd) return alert('没有任何修改！');
        if(confirm('修改后 Web 面板将自动重启。如果修改了端口，你需要手动调整浏览器地址。确定吗？')){
            fetchApi('/api/setting', {method:'POST', body:JSON.stringify({port, pwd})});
            alert('指令已发送！面板即将重启...');
            setTimeout(() => {
                if(port) window.location.href = window.location.protocol + '//' + window.location.hostname + ':' + port;
                else window.location.reload();
            }, 3000);
        }
    }
    async function logout() { await fetch('/api/logout', {method:'POST'}); window.location.reload(); }
    window.onload = loadData;
</script>
</body></html>
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def send_json(self, data):
        self.send_response(200); self.send_header('Content-type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))
    def send_text(self, text):
        self.send_response(200); self.send_header('Content-type', 'text/plain; charset=utf-8'); self.end_headers()
        self.wfile.write(text.encode('utf-8'))
        
    def check_auth(self):
        cookie = self.headers.get('Cookie', '')
        return f"auth={TOKEN}" in cookie

    def do_GET(self):
        if self.path == '/':
            self.send_response(200); self.send_header('Content-type', 'text/html; charset=utf-8'); self.end_headers()
            self.wfile.write((DASHBOARD_HTML if self.check_auth() else LOGIN_HTML).encode('utf-8'))
            return
        if not self.check_auth(): self.send_response(401); self.end_headers(); return
            
        if self.path == '/api/list':
            rules = []
            if os.path.exists(RULE_FILE):
                with open(RULE_FILE, 'r') as f:
                    for line in f:
                        p = line.strip().split()
                        if len(p) >= 3: rules.append({"l": p[0], "ra": p[1], "rp": p[2]})
            self.send_json(rules)
        elif self.path == '/api/status':
            act = False
            try: act = "active" in subprocess.run(['systemctl','is-active','realm'], capture_output=True, text=True).stdout
            except: pass
            self.send_json({"active": act})
        elif self.path == '/api/config':
            txt = "未生成"
            if os.path.exists(CONF_FILE):
                with open(CONF_FILE, 'r') as f: txt = f.read()
            self.send_text(txt)
        elif self.path == '/api/logs':
            try: txt = subprocess.run(['journalctl','-u','realm','-n','50','--no-pager'], capture_output=True, text=True).stdout
            except: txt = "无法获取日志"
            self.send_text(txt)

    def do_POST(self):
        cl = int(self.headers.get('Content-Length', 0))
        data = json.loads(self.rfile.read(cl).decode('utf-8')) if cl > 0 else {}
        
        if self.path == '/api/login':
            if data.get('pass') == PASS:
                self.send_response(200); self.send_header('Set-Cookie', f'auth={TOKEN}; Path=/; HttpOnly'); self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
            else:
                self.send_response(401); self.end_headers()
            return
        elif self.path == '/api/logout':
            self.send_response(200); self.send_header('Set-Cookie', 'auth=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT'); self.end_headers()
            return

        if not self.check_auth(): self.send_response(401); self.end_headers(); return

        if self.path == '/api/add':
            ra = data['ra']
            if ':' in ra and not ra.startswith('['): ra = f"[{ra}]"
            with open(RULE_FILE, 'a') as f: f.write(f"{data['l']} {ra} {data['rp']}\n")
            subprocess.run(['/usr/local/bin/realm-panel', 'sync'])
            self.send_json({"status":"ok"})
        elif self.path == '/api/del':
            idx = int(data['id'])
            if os.path.exists(RULE_FILE):
                with open(RULE_FILE, 'r') as f: lines = f.readlines()
                if 0 < idx <= len(lines):
                    del lines[idx-1]
                    with open(RULE_FILE, 'w') as f: f.writelines(lines)
            subprocess.run(['/usr/local/bin/realm-panel', 'sync'])
            self.send_json({"status":"ok"})
        elif self.path == '/api/restart':
            subprocess.run(['systemctl', 'restart', 'realm'])
            self.send_json({"status":"ok"})
        elif self.path == '/api/setting':
            n_port = data.get('port') or str(PORT)
            n_pass = data.get('pwd') or PASS
            self.send_json({"status":"ok"})
            subprocess.Popen(['/usr/local/bin/realm-panel', 'update_web', n_port, n_pass])

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
}

# --- 接收 API 与终端触发的命令 ---
if [[ "$1" == "sync" ]]; then
    sync_realm
    exit 0
fi

if [[ "$1" == "update_web" ]]; then
    echo "WEB_PORT=$2" > "$WEB_CONF"
    echo "WEB_PASS=\"$3\"" >> "$WEB_CONF"
    source "$WEB_CONF"
    install_web
    exit 0
fi

# 注册自身
if [ "$0" != "$PANEL_CMD" ]; then
    cp "$0" "$PANEL_CMD" 2>/dev/null
    chmod +x "$PANEL_CMD" 2>/dev/null
fi

# ==========================================
# 自动部署检测
# ==========================================
auto_install() {
    if [[ ! -f "$REALM_BIN" || ! -f "$WEB_PY" ]]; then
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${YELLOW} 检测到首次运行，正在全自动部署 Realm 与 Web 环境...${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        
        apt-get update -yqq && apt-get install -yqq python3 wget curl tar 2>/dev/null || yum install -y python3 wget curl tar 2>/dev/null
        
        local arch=$(uname -m)
        case "$arch" in
            x86_64) realm_arch="x86_64-unknown-linux-gnu" ;;
            aarch64|arm64) realm_arch="aarch64-unknown-linux-gnu" ;;
            *) echo -e "${RED}不支持的架构: $arch${PLAIN}"; exit 1 ;;
        esac
        local latest_ver=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -z "$latest_ver" ]] && latest_ver="v2.6.0"
        local dl_url="https://github.com/zhboner/realm/releases/download/${latest_ver}/realm-${realm_arch}.tar.gz"
        wget -qO /tmp/realm.tar.gz "$dl_url"
        tar -xzf /tmp/realm.tar.gz -C /tmp/ && mv /tmp/realm "$REALM_BIN" && chmod +x "$REALM_BIN"
        rm -f /tmp/realm.tar.gz

        init_env
        sync_realm

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
        
        install_web
        
        local public_ip=$(curl -s ifconfig.me)
        echo -e "\n${CYAN}🎉 部署全部完成！${PLAIN}"
        echo -e "===================================================="
        echo -e "🌐 Web 管理地址 : ${GREEN}http://${public_ip}:${WEB_PORT}${PLAIN}"
        echo -e "🔑 Web 登录密码 : ${YELLOW}${WEB_PASS}${PLAIN}   (仅密码验证)"
        echo -e "====================================================\n"
        read -p "按回车键进入终端面板..."
    fi
}

# ==========================================
# 终端 TUI 功能函数
# ==========================================
install_realm() {
    auto_install
    echo -e "${GREEN}核心组件检查完毕！${PLAIN}"
    sleep 1.5
}

uninstall_realm() {
    read -p "危险：确定要彻底卸载 Realm 面板并清空规则吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop realm realm-web 2>/dev/null
        systemctl disable realm realm-web 2>/dev/null
        rm -rf "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_DIR" "$PANEL_CMD" "$WEB_PY" "$WEB_SERVICE"
        systemctl daemon-reload
        echo -e "${GREEN}✅ 彻底卸载完毕！${PLAIN}"; exit 0
    fi
}

add_rule() {
    read -p "1. 本机监听端口: " l_port
    [[ ! "$l_port" =~ ^[0-9]+$ ]] && return
    if grep -q "^${l_port} " "$RULE_FILE" 2>/dev/null; then echo -e "${RED}端口已存在！${PLAIN}" && sleep 1.5 && return; fi
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
    echo -e "\n${CYAN}======================== 当前转发规则 ========================${PLAIN}"
    if [[ ! -s "$RULE_FILE" ]]; then echo -e "${YELLOW}暂无任何规则。${PLAIN}"
    else awk '{printf "[%-4s] | %-15s | %-30s\n", NR, $1, $2":"$3}' "$RULE_FILE"; fi
    echo -e "\n${YELLOW}>>> config.toml 配置文件源码 <<<${PLAIN}"
    [[ -f "$TOML_FILE" ]] && cat "$TOML_FILE" || echo "未生成"
}

delete_rule() {
    list_rules
    read -p "请输入要删除的序号 (回车取消): " idx
    [[ -z "$idx" ]] && return
    sed -i "${idx}d" "$RULE_FILE"
    apply_config
}

clear_rules() {
    read -p "确定清空吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then > "$RULE_FILE"; apply_config; fi
}

config_web() {
    echo -e "${CYAN}>>> 修改 Web 面板配置${PLAIN}"
    echo -e "当前端口: ${GREEN}${WEB_PORT}${PLAIN} | 当前密码: ${GREEN}${WEB_PASS}${PLAIN}"
    read -p "请输入新端口 (直接回车保持不变): " n_port
    read -p "请输入新密码 (直接回车保持不变): " n_pass
    
    [[ -z "$n_port" ]] && n_port=$WEB_PORT
    [[ -z "$n_pass" ]] && n_pass=$WEB_PASS
    
    # 调起自身参数更新 Web
    "$PANEL_CMD" update_web "$n_port" "$n_pass"
    echo -e "${GREEN}✅ Web 面板配置已更新并重启！${PLAIN}"
    sleep 1.5
}

show_menu() {
    clear
    local realm_version="未安装"
    local svc_status="${RED}■ 核心未安装${PLAIN}"
    local rule_count="0"
    local web_status="${RED}■ 异常${PLAIN}"
    
    if [[ -f "$REALM_BIN" ]]; then
        realm_version=$($REALM_BIN --version 2>/dev/null | awk '{print $2}')
        [[ -z "$realm_version" ]] && realm_version="未知"
        if systemctl is-active --quiet realm; then svc_status="${GREEN}▶ 运行中${PLAIN}"; else svc_status="${YELLOW}■ 已停止${PLAIN}"; fi
        [[ -f "$RULE_FILE" ]] && rule_count=$(wc -l < "$RULE_FILE" 2>/dev/null || echo 0)
    fi
    if systemctl is-active --quiet realm-web; then web_status="${GREEN}运行中 (端口: ${WEB_PORT})${PLAIN}"; fi

    echo -e "
${CYAN}#############################################################${PLAIN}
${CYAN}#               Realm 专线中转面板 (v${sh_ver})               #${PLAIN}
${CYAN}#############################################################${PLAIN}
 核心版本 : ${YELLOW}${realm_version}${PLAIN}
 运行状态 : ${svc_status}
 规则总数 : ${GREEN}${rule_count}${PLAIN} 条
 Web 面板 : ${web_status}
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
-------------------------------------------------------------
 ${YELLOW}11.${PLAIN}配置 Web 面板 ${CYAN}(修改端口/密码)${PLAIN}
 ${GREEN}0.${PLAIN} 退出面板
${CYAN}#############################################################${PLAIN}"
}

main() {
    [[ ! -t 0 ]] && exec < /dev/tty
    auto_install
    
    while true; do
        show_menu
        read -p "请输入数字选择 [0-11]: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_rule ;;
            4) delete_rule ;;
            5) clear_rules ;;
            6) list_rules; read -p "按回车键返回..." ;;
            7) systemctl start realm; echo -e "${GREEN}服务已启动！${PLAIN}"; sleep 1 ;;
            8) systemctl stop realm; echo -e "${GREEN}服务已停止！${PLAIN}"; sleep 1 ;;
            9) systemctl restart realm; echo -e "${GREEN}服务已重启！${PLAIN}"; sleep 1 ;;
            10) trap 'echo -e "\n已退出";' INT; journalctl -u realm -n 30 -f; trap - INT ;;
            11) config_web ;;
            0) echo -e "${GREEN}随时输入 realm-panel 唤出面板。${PLAIN}"; exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

main