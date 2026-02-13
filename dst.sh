#!/bin/bash

# ========================================
#   DST 饥荒联机版 服务器一键管理脚本
#   Author: Charles
#   功能: 安装 / 启动 / 停止 / 更新
# ========================================

# 全局只读常量
readonly DST_ROOT="$HOME/dst"
readonly STEAMCMD_ROOT="$HOME/steamcmd"
readonly KLEI_ROOT="$HOME/.klei/DoNotStarveTogether"
readonly DST_PORTS="10888 10999 10998"
readonly GITHUB_REPO_URL="https://github.com/Charles-JCH/dst.git"
readonly DEFAULT_TOKEN="pds-g^KU_XKeqpZXq^rtM08d2qtiy34ZRzi1P2wTLmrzTK3AcmnnMRePnXDjo="

# 日志函数
log() { echo -e "\033[1;32m>>> [系统]\033[0m $1"; }
warn() { echo -e "\033[1;33m>>> [警告]\033[0m $1"; }
error() { echo -e "\033[1;31m>>> [错误]\033[0m $1"; }

# 防火墙配置
configure_firewall() {
    log "正在检测防火墙配置..."
    
	# 检测是否安装 ufw
	if ! command -v ufw >/dev/null 2>&1; then
		warn "未检测到 ufw 防火墙工具，跳过自动配置。"
		warn "请手动确保 UDP 端口开放: $DST_PORTS"
		return 0 
	fi
	
	# 尝试激活 ufw
	if ! sudo ufw status | grep -q "Status: active"; then
		log "防火墙 ufw 未启用，如连接失败请执行 sudo ufw enable"
	fi
	
	# 开放 SSH 端口
	log "正在开放 SSH 端口 22/tcp"
	sudo ufw allow 22/tcp >/dev/null 2>&1
	
	# 开放 DST 所需 UDP 端口
	for port in $DST_PORTS; do
		log "正在开放端口 $port/udp"
		sudo ufw allow "$port"/udp >/dev/null 2>&1
	done
	
	log "防火墙端口配置已更新"
}

# 启动状态检测
wait_for_startup() {
	local LOG_FILE=$1
	local SCREEN_NAME=$2
    local TIMEOUT_INIT=10
    local COUNTER=0
	
	log "正在监视服务器启动状态..."
	
	while [ $COUNTER -lt $TIMEOUT_INIT ]; do
        if ! screen -list | grep -q "$SCREEN_NAME"; then
            error "服务器进程 ($SCREEN_NAME) 意外退出"
            error "可能原因： Mod配置错误 / Token 无效 / 端口未开放"
            [ -f "$LOG_FILE" ] && cat "$LOG_FILE"
            return 1
        fi
		
        if [ -s "$LOG_FILE" ]; then
            break
        fi
		
        sleep 1
        ((COUNTER++))
    done
	
	if [ ! -s "$LOG_FILE" ]; then
		error "启动异常： 10秒内未检测到日志输出"
        return 1
    fi
	
    log "日志已建立，正在等待世界生成..."
	tail -n +1 -f "$LOG_FILE" | while read line; do
        echo "$line"
        
        if echo "$line" | grep -q "Sim paused"; then
             log "服务器启动成功 (Sim paused)！"
             pkill -P $$ tail
             exit 0
        fi
    done
}

# 环境安装
install_env() {
	# 检测是否已有 DST 环境
	if [ -f "$DST_ROOT/bin/dontstarve_dedicated_server_nullrenderer" ]; then
        return 0
    fi
	
	log "检测到新环境，开始自动部署..."
	log "[1/5] 安装系统依赖..."
	sudo mkdir -p /etc/needrestart
	if [ -d "/etc/needrestart" ]; then
        sudo tee /etc/needrestart/needrestart.conf >/dev/null <<'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = -1;
$nrconf{verbosity} = 0;
EOF
    fi
	
    sudo DEBIAN_FRONTEND=noninteractive add-apt-repository multiverse -y >/dev/null 2>&1
    sudo DEBIAN_FRONTEND=noninteractive dpkg --add-architecture i386 >/dev/null 2>&1
    sudo DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libstdc++6:i386 libgcc1:i386 libcurl4-gnutls-dev:i386 screen git ufw >/dev/null 2>&1
	
	configure_firewall
	
	# 安装 SteamCMD
	log "[2/5] 安装 SteamCMD..."
	mkdir -p "$STEAMCMD_ROOT" && cd "$STEAMCMD_ROOT" || exit
    if [ ! -f "steamcmd.sh" ]; then
        wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxvf - >/dev/null 2>&1
    fi
	
	# 安装 DST
	log "[3/5] 下载/更新 DST 服务端..."
	"$STEAMCMD_ROOT/steamcmd.sh" +force_install_dir "$DST_ROOT" +login anonymous +app_update 343050 validate +quit
	
	# 修复库文件
	mkdir -p "$DST_ROOT/bin/lib32/"
	cp -f "$DST_ROOT/steamclient.so" "$DST_ROOT/bin/lib32/"
	
	# 拉取存档
	log "[4/5] 拉取默认存档..."
	mkdir -p "$KLEI_ROOT"
	local CLUSTER_DIR="$KLEI_ROOT/Cluster_1"
	if [ ! -d "$CLUSTER_DIR" ]; then
        git clone --depth 1 "$GITHUB_REPO_URL" "$CLUSTER_DIR"
        rm -rf "$CLUSTER_DIR/.git"
    fi
	
	# 写入 token
	log "[5/5] 写入 Cluster Token..."
	if [ ! -f "$CLUSTER_DIR/cluster_token.txt" ]; then
        echo "$DEFAULT_TOKEN" > "$CLUSTER_DIR/cluster_token.txt"
    fi
	
	log "环境部署完成！"
}

# 启动服务器
start_server() {
	local SLOT=${1:-1}
	local LOG_FILE="$HOME/result${SLOT}.log"
	
	if screen -list | grep -q "master${SLOT}"; then
        warn "Master${SLOT} 已运行，请勿重复启动"
        return 0
    fi
	
	# 清空日志
    echo "" > "$LOG_FILE"
	
	cd "$DST_ROOT/bin" || exit
	log "正在启动 Master${SLOT} ..."
	screen -dmS "master${SLOT}" bash -c "./dontstarve_dedicated_server_nullrenderer -console -cluster Cluster_${SLOT} -shard Master | sed 's/^/Master: /' > ${LOG_FILE} 2>&1"
	
	log "Master 已启动，等待 15 秒预热..."
	for i in {1..15}; do
        if ! screen -list | grep -q "master${SLOT}"; then
             error "Master 进程在预热期间意外退出！"
             cat "$LOG_FILE"
             return 1
        fi
        sleep 1
    done
	
	log "正在启动 Caves${SLOT} ..."
	screen -dmS "caves${SLOT}" bash -c "./dontstarve_dedicated_server_nullrenderer -console -cluster Cluster_${SLOT} -shard Caves | sed 's/^/Caves: /' >> ${LOG_FILE} 2>&1"

	wait_for_startup "$LOG_FILE" "master${SLOT}"
}

# 停止服务器
stop_server() {
	local SLOT=${1:-1}

	if ! screen -list | grep -q "master${SLOT}"; then
        warn "Master${SLOT} 未运行"
        return 1
    fi
	
	log "正在停止 Cluster_${SLOT} ..."
	screen -S "master${SLOT}" -X stuff 'c_announce("服务器将在5秒后关闭")\n'
    sleep 1
	
	for i in 5 4 3 2 1; do
        screen -S "master${SLOT}" -X stuff "c_announce(\"$i\")\n"
        sleep 1
    done
	
	screen -S "caves${SLOT}" -X stuff 'c_shutdown(true)\n'
    screen -S "master${SLOT}" -X stuff 'c_shutdown(true)\n'
	
	log "等待进程退出..."
    local retry=0
    while screen -list | grep -q "master${SLOT}"; do
        sleep 1
        ((retry++))
        if [ $retry -gt 10 ]; then
            warn "进程未响应，强制关闭..."
            screen -S "master${SLOT}" -X quit
            screen -S "caves${SLOT}" -X quit
            break
        fi
    done

	log "Cluster_${SLOT} 已停止"
}

# 更新服务器
update_server() {
	if screen -list | grep -q "master"; then
		error "请先停止所有运行中的服务器"
        return 1
    fi
	
	log "正在更新 DST 服务端..."
	"$STEAMCMD_ROOT/steamcmd.sh" +force_install_dir "$DST_ROOT" +login anonymous +app_update 343050 validate +quit
	
	log "更新完成"
}

show_menu() {
	clear
    echo "========================="
    log "   DST 服务器管理脚本"
    echo "========================="
    echo "1. 启动服务器"
    echo "2. 停止服务器"
    echo "3. 更新服务端"
    echo "4. 退出"
    echo -n "请选择 [1-4]: "
	
    read -r action_option
	
	case "$action_option" in
        1) start_server "1" ;;
        2) stop_server "1" ;;
        3) update_server ;;
        4) exit 0 ;;
        *) warn "无效选项" ;;
    esac
	
    echo "按回车继续..."
    read
}

# 主处理
install_env

if [ $# -gt 0 ]; then
    # === 自动化模式 ===
    case "$1" in
        "start") start_server "${2:-1}" ;;
        "stop") stop_server "${2:-1}" ;;
        "update") update_server ;;
        *) echo "Usage: ./dst.sh [start|stop|update] [1-5]"; exit 1 ;;
    esac
else
    # === 交互模式 ===
    while true; do
        show_menu
    done
fi
