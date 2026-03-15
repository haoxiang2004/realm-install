#!/bin/bash

# ==========================================
# Realm 智控面板 V3.0 (全自动化 + 全功能 Web)
# 默认 Web 端口: 8081 | 默认密码: 123456
# ==========================================

export LANG=en_US.UTF-8
sh_ver="3.0.0"

# --- 全局默认配置 ---
WEB_PORT=8081
WEB_PASS="123456"

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

# --- API 同步接口 (给 Web 后端调用的静默指令) ---
if [[ "$1" == "sync" ]]; then
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

# 注册全局命令
if [ "$0" != "$PANEL_CMD" ]; then
    cp "$0" "$PANEL_CMD" 2>/dev/null
    chmod +x "$PANEL_CMD" 2>/dev/null
fi

init_env() {
    mkdir -p "$CONFIG_DIR"
    touch "$RULE_FILE"
}

# ==========================================
# 安装核心组件 (Realm)
# ==========================================
install_realm_core() {
    echo -e "${CYAN}[1/3] 正在自动部署 Realm 核心组件...${PLAIN}"
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
}

# ==========================================
# 部署全功能 Web 面板
# ==========================================
install_web_core() {
    echo -e "${CYAN}[2/3] 正在生成高颜值 Web 控制台...${PLAIN}"

    # 注入动态变量
    cat << EOF > "$WEB_PY"
PORT = $WEB_PORT
PASS = "$WEB_PASS"
EOF

    # 写入纯 Python 无依赖 Web 服务器核心代码
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
        .form-control:focus { box-shadow: none; border-color: #667eea; }
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
        <span class="navbar-brand fw-bold">🚀 Realm 智控中心 V3.0</span>
        <button class="btn btn-outline-light btn-sm" onclick="logout()">安全退出</button>
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
        // 状态
        const stRes = await fetchApi('/api/status'); const st = await stRes.json();
        const b = document.getElementById('statusBadge');
        if(st.active){ b.className='badge bg-success'; b.innerText='▶ 运行中'; }else{ b.className='badge bg-danger'; b.innerText='■ 已停止'; }
        // 规则表
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
        if f"auth={TOKEN}" in cookie: return True
        return False

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
            txt = "配置文件未找到。"
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

# ==========================================
# 自动化执行入口
# ==========================================
auto_install() {
    # 如果没安装，则执行全自动静默部署
    if [[ ! -f "$REALM_BIN" || ! -f "$WEB_PY" ]]; then
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${YELLOW} 检测到首次运行，正在全自动部署 Realm 与 Web 环境...${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        
        # 安装基础依赖
        apt-get update -yqq && apt-get install -yqq python3 wget curl tar 2>/dev/null || yum install -y python3 wget curl tar 2>/dev/null
        
        install_realm_core
        install_web_core
        
        local public_ip=$(curl -s ifconfig.me)
        echo -e "\n${CYAN}[3/3] 🎉 部署全部完成！${PLAIN}"
        echo -e "===================================================="
        echo -e "🌐 Web 管理地址 : ${GREEN}http://${public_ip}:${WEB_PORT}${PLAIN}"
        echo -e "🔑 Web 登录密码 : ${YELLOW}${WEB_PASS}${PLAIN}   (仅密码，无用户名)"
        echo -e "⚠️ 请务必在云服务器防火墙放行 ${WEB_PORT} 端口！"
        echo -e "====================================================\n"
        read -p "按回车键进入终端面板..."
    fi
}

get_status() {
    if systemctl is-active --quiet realm; then echo -e "${GREEN}运行中${PLAIN}"
    else echo -e "${RED}已停止${PLAIN}"; fi
}

# --- 终端面板备用 UI ---
main() {
    [[ ! -t 0 ]] && exec < /dev/tty
    auto_install # 触发全自动检测与安装
    
    while true; do
        clear
        local rule_count="0"
        [[ -f "$RULE_FILE" ]] && rule_count=$(wc -l < "$RULE_FILE" 2>/dev/null)
        
        echo -e "
${CYAN}#############################################################${PLAIN}
${CYAN}#               Realm 智控面板 V${sh_ver} (终端版)              #${PLAIN}
${CYAN}#############################################################${PLAIN}
 转发核心 : $(get_status)    |   规则总数 : ${GREEN}${rule_count}${PLAIN}
 Web 面板 : ${GREEN}运行中 (端口: ${WEB_PORT})${PLAIN}
-------------------------------------------------------------
 提示: 我们强烈建议您使用 Web 浏览器进行可视化操作！
 若 Web 面板无法访问，请检查服务器的安全组和防火墙设置。
-------------------------------------------------------------
 ${CYAN}1.${PLAIN} 重装 / 更新 Realm 核心代码
 ${CYAN}2.${PLAIN} 修改 Web 端口或密码 (将重新生成)
 ${RED}3.${PLAIN} 彻底卸载 Realm 与 Web 面板
-------------------------------------------------------------
 ${GREEN}0.${PLAIN} 退出终端
${CYAN}#############################################################${PLAIN}"
        read -p "请选择操作 [0-3]: " opt
        case $opt in
            1) install_realm_core; echo "更新完成"; sleep 1 ;;
            2) 
               read -p "新 Web 端口: " WEB_PORT
               read -p "新 Web 密码: " WEB_PASS
               install_web_core; read -p "按回车返回..." ;;
            3) 
               read -p "确定彻底卸载吗？(y/n): " confirm
               if [[ "$confirm" == "y" ]]; then
                   systemctl stop realm realm-web; systemctl disable realm realm-web
                   rm -rf "$REALM_BIN" "$SERVICE_FILE" "$CONFIG_DIR" "$PANEL_CMD" "$WEB_PY" "$WEB_SERVICE"
                   echo -e "${GREEN}卸载完毕！${PLAIN}"; exit 0
               fi ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

main