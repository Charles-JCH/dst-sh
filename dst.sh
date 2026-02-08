#!/bin/bash

#config
DST_ROOT=~/dst
STEAMCMD_ROOT=~/steamcmd
KLEI_ROOT=~/.klei/DoNotStarveTogether

GITHUB_REPO_URL="https://github.com/Charles-JCH/dst.git"
DEFAULT_TOKEN="pds-g^KU_XKeqpZXq^rtM08d2qtiy34ZRzi1P2wTLmrzTK3AcmnnMRePnXDjo="

wait_for_startup() {
	local LOG_FILE=$1
	echo ">>> 正在监视启动日志..."
	
	tail -n 0 -f "$LOG_FILE" | while read line; do
        echo "$line"
        if echo "$line" | grep -q "is now connected"; then
            echo ">>> [系统] 检测到服务器启动成功！"
            pkill -P $$ tail
            return 0
        fi
        
        if echo "$line" | grep -q "Sim paused"; then
             echo ">>> [系统] 世界生成完毕，服务器已就绪！"
             pkill -P $$ tail
             return 0
        fi
    done
}

install_env() {
	#check environment
	if [ -f "$DST_ROOT/bin/dontstarve_dedicated_server_nullrenderer" ]; then
        return 0
    fi
	
	echo ">>> [系统] 检测到新环境, 开始一键部署..."
	echo ">>> [1/5] 安装系统依赖..."
	
	#install environment
	sudo mkdir -p /etc/needrestart
	sudo tee /etc/needrestart/needrestart.conf >/dev/null <<'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = -1;
$nrconf{verbosity} = 0;
EOF
    sudo DEBIAN_FRONTEND=noninteractive add-apt-repository multiverse -y
    sudo DEBIAN_FRONTEND=noninteractive dpkg --add-architecture i386
    sudo DEBIAN_FRONTEND=noninteractive apt update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libstdc++6:i386 libgcc1:i386 libcurl4-gnutls-dev:i386 screen git
	
	#install steamcmd
	echo ">>> [2/5] 安装 SteamCMD..."
	mkdir -p "$STEAMCMD_ROOT" && cd "$STEAMCMD_ROOT" || exit
    wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxvf -
	
	#install dst
	echo ">>> [3/5] 下载/更新 DST 服务端 (可能需要几分钟)..."
	"$STEAMCMD_ROOT/steamcmd.sh" +force_install_dir "$DST_ROOT" +login anonymous +app_update 343050 validate +quit
	mkdir -p "$DST_ROOT/bin/lib32/"
	cp -f "$DST_ROOT/steamclient.so" "$DST_ROOT/bin/lib32/"
	
	#pull dst save from github
	echo ">>> [4/5] 正在从 GitHub 拉取默认存档..."
	mkdir -p "$KLEI_ROOT"
	CLUSTER_DIR="$KLEI_ROOT/Cluster_1"
	git clone "$GITHUB_REPO_URL" "$CLUSTER_DIR"
	rm -rf "$CLUSTER_DIR/.git"
	
	#write token
	echo ">>> [5/5] 配置 Cluster Token..."
	echo "$DEFAULT_TOKEN" > "$CLUSTER_DIR/cluster_token.txt"
	echo ">>> 环境部署完毕！"
}

start_server() {
	#check parameter
	local SLOT=$1
	if [ -z "$SLOT" ]; then 
		SLOT=1
	fi
	
	#create log
	local LOG_FILE=~/result${SLOT}.log
	
	#check status
	if screen -list | grep -q "master${SLOT}"; then
        echo "Master${SLOT} 已经在运行中。"
        return 0
    fi
	
	echo ">>> 正在启动存档 Cluster_$SLOT ..."
	#clear log
    echo "" > "$LOG_FILE"

	#start dst
	cd "$DST_ROOT/bin" || exit
	screen -dmS "master${SLOT}" bash -c "./dontstarve_dedicated_server_nullrenderer -console -cluster Cluster_${SLOT} -shard Master | sed 's/^/Master: /' > ${LOG_FILE} 2>&1"
	sleep 15
	screen -dmS "caves${SLOT}" bash -c "./dontstarve_dedicated_server_nullrenderer -console -cluster Cluster_${SLOT} -shard Caves | sed 's/^/Caves: /' >> ${LOG_FILE} 2>&1"

	#listening log
	wait_for_startup "$LOG_FILE"
}

stop_server() {
	#check parameter
	local SLOT=$1
	if [ -z "$SLOT" ]; then
		SLOT=1
	fi
	
	#check status
	if ! screen -list | grep -q "master${SLOT}"; then
        echo "提示: Master${SLOT} 未运行。"
        return 1
    fi
	
	#stop dst
	echo ">>> 正在停止存档 Cluster_$SLOT ..."
	screen -S "master${SLOT}" -X stuff 'c_announce("服务器将在5秒后关闭")\n'
    sleep 1
    screen -S "master${SLOT}" -X stuff 'c_announce("5")\n'
	sleep 1
    screen -S "master${SLOT}" -X stuff 'c_announce("4")\n'
	sleep 1
    screen -S "master${SLOT}" -X stuff 'c_announce("3")\n'
	sleep 1
    screen -S "master${SLOT}" -X stuff 'c_announce("2")\n'
    sleep 1
    screen -S "master${SLOT}" -X stuff 'c_announce("1")\n'
    sleep 1
	screen -S "caves${SLOT}" -X stuff 'c_shutdown(true)\n'
    screen -S "master${SLOT}" -X stuff 'c_shutdown(true)\n'
	sleep 3
	echo ">>> 存档 Cluster_$SLOT 已停止。"
}

update_server() {
	#check status
	if screen -list | grep -q "master"; then
        echo "错误: 请先停止所有运行中的服务器!"
        return 1
    fi

	#update dst
	echo ">>> 正在连接 Steam 更新 DST 服务端..."
	"$STEAMCMD_ROOT/steamcmd.sh" +force_install_dir "$DST_ROOT" +login anonymous +app_update 343050 validate +quit
	echo ">>> 更新完成!"
}

show_menu() {
	clear
    echo "========================="
    echo "   DST 服务器管理脚本"
    echo "========================="
    echo "1. 启动服务器 (存档1)"
    echo "2. 停止服务器 (存档1)"
    echo "3. 更新服务端"
    echo "4. 退出"
    echo -n "请输入选项 [1-4]: "
    read -r action_option
	
	case "$action_option" in
        1) start_server "1" ;;
        2) stop_server "1" ;;
        3) update_server ;;
        4) exit 0 ;;
        *) echo "无效选项" ;;
    esac
    echo "按回车键继续..."
    read
}

install_env
if [ $# -gt 0 ]; then
    # === 自动化模式 ===
    ACTION=$1
    ARG=$2
    case "$ACTION" in
        "start") start_server "$ARG" ;;
        "stop") stop_server "$ARG" ;;
        "update") update_server ;;
        *) echo "Usage: ./dst.sh [start|stop|update] [1-5]"; exit 1 ;;
    esac
else
    # === 交互模式 ===
    while true; do
        show_menu
    done
fi