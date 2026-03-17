# Realm 智控面板 (终端 TUI + Web 可视化双控)

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat-square&logo=gnu-bash)
![Platform](https://img.shields.io/badge/Platform-Linux-blue?style=flat-square&logo=linux)
![License](https://img.shields.io/badge/License-MIT-orange?style=flat-square)

这是一个专为 [Realm](https://github.com/zhboner/realm) 打造的极简、高效、自动化的管理面板。V3.0+ 版本全面进化，不仅保留了原汁原味的终端 TUI 菜单，更引入了**全自动静默部署**与**高颜值 Web 控制台**，实现真正的“一键双控”。

## ✨ 核心特性

- **🚀 全自动极速部署**：运行脚本后全自动拉取核心、配置环境、启动网页端，全程零干预。
- **🌐 轻奢级 Web 控制台**：自带美观的 Web UI，支持极简密码登录，增删规则、查日志、看配置一站式搞定。
- **🖥️ 终端 TUI 满血保留**：全局注册 `realm-panel` 命令，随时随地在终端呼出传统管理菜单。
- **⚡ 完美双栈支持**：添加节点时自动绑定 `[::]`，原生支持同一端口同时接管 IPv4 和 IPv6 访客流量。
- **🛡️ 纯净卸载逻辑**：内置一键彻底卸载功能，自动清理二进制、配置及服务文件，不留任何垃圾。

---

## 📦 极速安装 / 启动

在你全新的 Linux 服务器上，只需执行以下一键命令即可全自动完成安装：

```bash
wget -O realm-install.sh https://raw.githubusercontent.com/haoxiang2004/realm-install/main/realm-install.sh && bash realm-install.sh
```

```bash
wget -O realm-install.sh https://host.wxgwxha.eu.org/https://raw.githubusercontent.com/haoxiang2004/realm-install/main/realm-install.sh && bash realm-install.sh
```


> **💡 提示**：首次运行后，脚本会自动将自身注册为系统级命令。以后你只需在终端直接输入 `realm-panel` 即可唤出管理菜单！

---

## 🌐 Web 面板访问指南

安装完成后，系统会自动拉起 Web 管理面板：

- **访问地址**：`http://你的服务器IP:8081`
- **默认密码**：`123456` (纯密码验证，无需用户名)

*⚠️ 注意：请务必在你的云服务器控制台（安全组/防火墙）中放行 **8081** (Web 端口) 以及你所添加的转发监听端口的 TCP/UDP 流量。*

---

## 🛠️ 终端 TUI 菜单一览

如果你习惯使用命令行，输入 `realm-panel` 即可看到如下直观的管理界面：

```text
#############################################################
#               Realm 专线中转面板 (v3.1.0)               #
#############################################################
 核心版本 : v2.6.0
 运行状态 : ▶ 运行中
 规则总数 : 2 条
 Web 面板 : 运行中 (端口: 8081)
-------------------------------------------------------------
 1. 安装 / 更新 Realm 核心
 2. 彻底卸载 Realm 面板
-------------------------------------------------------------
 3. 添加转发规则 (原生双栈支持)
 4. 删除转发规则
 5. 清空全部规则
 6. 查看规则列表与底层配置
-------------------------------------------------------------
 7. 启动 Realm 服务
 8. 停止 Realm 服务
 9. 重启 Realm 服务
 10.查看 Realm 运行日志
 0. 退出面板
#############################################################
```

---

## 📖 技术原理解析

传统的 `iptables` 转发在内核态运行，IPv4/v6 物理隔离，跨协议转换极其复杂。Realm 带来了降维打击的解决方案：
1. **用户态 L4 代理**：接管 Socket 连接，天然无视协议壁垒，轻松实现 4-to-6 或 6-to-4。
2. **单端口双栈监听**：利用 Linux `bindv6only=0` 特性，默认绑定 `[::]`，实现同一个端口吃进 IPv4/IPv6 双栈流量。

---

## 📜 开源协议

本项目基于 MIT License 协议开源。欢迎提交 Issue 或 Pull Request 来共同完善这个工具！


