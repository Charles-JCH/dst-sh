#!/bin/bash

# ========================================
#   DST 饥荒联机版 服务器一键管理脚本
#   Author: Charles
#   功能: 部署 / 启动 / 停止 / 更新
# ========================================

# 定义charles用户及密码
readonly TARGET_USER="charles"
readonly TARGET_PASS="123456"

# 颜色定义
readonly RED="\033[1;31m"
readonly GREEN="\033[1;32m"
readonly YELLOW="\033[1;33m"
readonly BLUE="\033[1;34m"
readonly RESET="\033[0m"

# 日志函数
log() { echo -e "${GREEN}>>> [系统]${RESET} $1"; }
warn() { echo -e "${YELLOW}>>> [警告]${RESET} $1"; }
error() { echo -e "${RED}>>> [错误]${RESET} $1"; }

# 打印颜色字体
print_red() { echo -e "${RED}$1${RESET}"; }
print_green() { echo -e "${GREEN}$1${RESET}"; }
print_yellow() { echo -e "${YELLOW}$1${RESET}"; }
print_blue() { echo -e "${BLUE}$1${RESET}"; }

# 如果当前是 root，则创建用户并切换
if [ "$(id -u)" -eq 0 ]; then
    log "检测到当前为 Root 用户，正在切换至普通用户 '$TARGET_USER'..."

    # 创建用户 (如果不存在)
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        log "正在创建用户: $TARGET_USER"
        useradd -m -s /bin/bash "$TARGET_USER"
        echo "$TARGET_USER:$TARGET_PASS" | chpasswd
        log "用户密码已设置为: $TARGET_PASS"
    fi

    # 配置 sudo 免密权限
    if [ ! -f "/etc/sudoers.d/$TARGET_USER" ]; then
        log "配置 sudo 免密权限..."
        # 确保 sudo 已安装
		if ! command -v sudo >/dev/null 2>&1; then
             apt-get update >/dev/null 2>&1 && apt-get install -y sudo >/dev/null 2>&1
        fi
        echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$TARGET_USER"
        chmod 0440 "/etc/sudoers.d/$TARGET_USER"
    fi

    # 将当前脚本复制到 charles 的目录下，确保有权访问
    SCRIPT_NAME=$(basename "$0")
    TARGET_SCRIPT="/home/$TARGET_USER/$SCRIPT_NAME"
    
    cp "$0" "$TARGET_SCRIPT"
    chown "$TARGET_USER:$TARGET_USER" "$TARGET_SCRIPT"
    chmod +x "$TARGET_SCRIPT"

    log "切换身份并重新执行命令..."
	
    # 使用 su - 切换环境，并透传所有参数 ($@)
    exec su - "$TARGET_USER" -c "bash $TARGET_SCRIPT $*"
fi

# =======================================================
#  注意：以下代码均在 'charles' 用户下执行 (已拥有 sudo 权限)
# =======================================================

# 全局只读常量
readonly DST_ROOT="$HOME/dst"
readonly DST_BIN="$DST_ROOT/bin/dontstarve_dedicated_server_nullrenderer"
readonly STEAMCMD_ROOT="$HOME/steamcmd"
readonly KLEI_ROOT="$HOME/.klei/DoNotStarveTogether"
readonly DST_PORTS="10888 10999 10998"
readonly GITHUB_REPO_URL="https://github.com/Charles-JCH/dst.git"
readonly DEFAULT_TOKEN="pds-g^KU_XKeqpZXq^rtM08d2qtiy34ZRzi1P2wTLmrzTK3AcmnnMRePnXDjo="

# 防火墙配置
configure_firewall() {
    log "正在检测防火墙配置..."
    
	# 检测是否安装 ufw
	if ! command -v ufw >/dev/null 2>&1; then
		warn "未检测到 ufw 防火墙，跳过自动配置。"
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

# 重试机制
update_dst_with_retry() {
    local max_attempts=5
    local attempt=1
    local success=0

    # 确保 SteamCMD 存在
    if [ ! -f "$STEAMCMD_ROOT/steamcmd.sh" ]; then
        error "SteamCMD 未找到，无法更新！"
        return 1
    fi

    while [ $attempt -le $max_attempts ]; do
        log "正在下载/更新 DST 服务端 (第 $attempt/$max_attempts 次尝试)..."
        
        # 执行下载命令
        "$STEAMCMD_ROOT/steamcmd.sh" +force_install_dir "$DST_ROOT" +login anonymous +app_update 343050 validate +quit
        
        # 校验是否下载成功
        if [ -f "$DST_BIN" ]; then
            log "DST 服务端校验成功！"
            
            # 修复库文件
            mkdir -p "$DST_ROOT/bin/lib32/"
            cp -f "$DST_ROOT/steamclient.so" "$DST_ROOT/bin/lib32/"
            
            success=1
            break
        else
            warn "连接 Steam 服务器超时，5秒后重试"
            sleep 5
            ((attempt++))
        fi
    done

    if [ $success -eq 0 ]; then
        error "下载失败，请检查网络连接 (是否能连接 Steam 服务器)。"
        return 1
    fi
    return 0
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
	while read line; do
		echo "$line"
		
		if echo "$line" | grep -q "is now connected"; then
			 log "服务器启动成功！"
			 pkill -P $$ tail
			 exit 0
		fi
	done < <(tail -n +1 -f "$LOG_FILE")
}

# 环境安装
install_env() {
	# 检测是否已有 DST 环境
	if [ -f "$DST_BIN" ]; then
        return 0
    fi
	
	log "检测到新环境，开始自动部署..."
	log "[1/3] 安装系统依赖..."
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
	log "[2/3] 安装 SteamCMD..."
	mkdir -p "$STEAMCMD_ROOT" && cd "$STEAMCMD_ROOT" || exit
    if [ ! -f "steamcmd.sh" ]; then
        wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxvf - >/dev/null 2>&1
    fi
	
	# 安装 DST
	log "[3/3] 下载/更新 DST 服务端..."
	if ! update_dst_with_retry; then
        exit 1
    fi
	
	# 修复库文件
	mkdir -p "$DST_ROOT/bin/lib32/"
	cp -f "$DST_ROOT/steamclient.so" "$DST_ROOT/bin/lib32/"
	
	log "环境部署完成！"
}

# 启动服务器
start_server() {
	local SLOT=${1:-1}
	local CUSTOM_TOKEN=$2
	local LOG_FILE="$HOME/result${SLOT}.log"
	
	local CLUSTER_DIR="$KLEI_ROOT/Cluster_${SLOT}"
	# 拉取存档
	if [ ! -d "$CLUSTER_DIR" ]; then
		log "检测到存档 Cluster_${SLOT} 不存在，拉取默认存档..."
		mkdir -p "$KLEI_ROOT"
        git clone --depth 1 "$GITHUB_REPO_URL" "$CLUSTER_DIR"
        rm -rf "$CLUSTER_DIR/.git"
    fi
	
	local TOKEN_TO_USE="${CUSTOM_TOKEN:-$DEFAULT_TOKEN}"
	# 写入 token
	log "写入 Cluster Token..."
    echo "$TOKEN_TO_USE" > "$CLUSTER_DIR/cluster_token.txt"
	
	# 检测进程是否已运行
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
	if update_dst_with_retry; then
        log "更新完成"
    else
        return 1
    fi
}

show_menu() {
	clear
    echo "========================="
	print_green "   DST 服务器管理脚本"
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
if [ $# -gt 0 ]; then
    # === 自动化模式 ===
    case "$1" in
		"deploy") install_env ;;
        "start") start_server "${2:-1}" "$3" ;;
        "stop") stop_server "${2:-1}" ;;
        "update") update_server ;;
        *) echo "Usage: ./dst.sh [deploy|start|stop|update] [1-5]"; exit 1 ;;
    esac
else
    # === 交互模式 ===
	install_env
    while true; do
        show_menu
    done
fi
