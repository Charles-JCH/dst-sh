#!/usr/bin/env bash
# ============================================================
#   DST 饥荒联机版 服务器一键管理脚本
#   Author : Charles
#   功能   : 部署 / 启动 / 停止 / 更新
# ============================================================
set -euo pipefail

# ============================================================
# 全局常量
# ============================================================
readonly TARGET_USER="charles"
readonly TARGET_PASS="123456"

readonly DST_ROOT="$HOME/dst"
readonly DST_BIN="$DST_ROOT/bin/dontstarve_dedicated_server_nullrenderer"
readonly STEAMCMD_DIR="$HOME/steamcmd"
readonly STEAMCMD_TAR_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
readonly KLEI_DIR="$HOME/.klei/DoNotStarveTogether"

readonly GITHUB_REPO_URL="https://github.com/Charles-JCH/dst.git"
readonly DEFAULT_TOKEN="pds-g^KU_XKeqpZXq^rtM08d2qtiy34ZRzi1P2wTLmrzTK3AcmnnMRePnXDjo="
readonly DST_PORTS="10888 10999 10998"

# ============================================================
# 颜色 & 日志
# ============================================================
readonly C_RED="\033[1;31m"
readonly C_GREEN="\033[1;32m"
readonly C_YELLOW="\033[1;33m"
readonly C_RESET="\033[0m"

info()  { echo -e "${C_GREEN}[$(date '+%F %T')] [INFO ]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[$(date '+%F %T')] [WARN ]${C_RESET} $*"; }
error() { echo -e "${C_RED}[$(date '+%F %T')] [ERROR]${C_RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# ============================================================
# 系统检测
# ============================================================
check_os_version() {
    info "检查系统版本"

    if [[ ! -f /etc/os-release ]]; then
        die "无法识别当前系统: /etc/os-release 不存在"
    fi

    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "当前系统为 ${PRETTY_NAME:-未知}，为保证稳定性，此脚本仅支持 Ubuntu(推荐 Ubuntu 22.04 LTS)"
    fi

    info "系统检测通过: ${PRETTY_NAME}"
}

# ============================================================
# 创建用户 charles 并赋予 sudo 免密权限
# ============================================================
bootstrap_user() {
    # 查看当前用户是否是 charles
    [[ "$(whoami)" == "$TARGET_USER" ]] && return 0

    # 创建用户
    if ! id "$TARGET_USER" &>/dev/null; then
        info "创建用户 $TARGET_USER"
        useradd -m -s /bin/bash "$TARGET_USER"
        echo "$TARGET_USER:$TARGET_PASS" | chpasswd
    fi

    # 配置 sudo 免密
    local sudoers_file="/etc/sudoers.d/$TARGET_USER"
    if [[ ! -f "$sudoers_file" ]]; then
        info "配置 sudo 免密权限"
        if ! command -v sudo &>/dev/null; then
            info "sudo 不存在，正在安装..."
            apt-get update -qq
            apt-get install -y sudo
        fi
        echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
        chmod 0440 "$sudoers_file"
    fi

    # 复制脚本到 charles 用户目录
    local script_name
    script_name=$(basename "$0")
    local script_path
    script_path=$(realpath "$0")
    local target_script="/home/$TARGET_USER/$script_name"
    cp "$script_path" "$target_script"
    chown "$TARGET_USER:$TARGET_USER" "$target_script"
    chmod +x "$target_script"

    # 切换 charles 用户执行脚本
    info "切换用户 $TARGET_USER 重新执行"
    local safe_args
    safe_args=$(printf '%q ' "$@")
    exec su - "$TARGET_USER" -c "bash $target_script $safe_args"
}

# ============================================================
# 防火墙配置
# ============================================================
configure_firewall() {
    info "检查防火墙配置"

    if ! command -v ufw &>/dev/null; then
        warn "未检测到 ufw，请手动开放 UDP 端口: $DST_PORTS"
        return 0
    fi

    if ! sudo ufw status | grep -q "Status: active"; then
        warn "ufw 未启用，如遇连接问题请执行: sudo ufw enable"
    fi

    sudo ufw allow 22/tcp
    info "已放行端口 22/tcp"
    for port in $DST_PORTS; do
        sudo ufw allow "$port/udp"
        info "已放行端口 $port/udp"
    done
}

# ============================================================
# SteamCMD 安装
# ============================================================
install_steamcmd() {
    [[ -f "$STEAMCMD_DIR/steamcmd.sh" ]] && return 0

    mkdir -p "$STEAMCMD_DIR"

    local tmp_file="/tmp/steamcmd_linux.tar.gz"
    local success=0

    local max_attempts=3
    for (( i = 1; i <= max_attempts; i++ )); do
        info "下载 SteamCMD ($i/${max_attempts})..."

        # wget -c 支持断点续传，防止每次都从头下
        if wget -c -O "$tmp_file" -qq "$STEAMCMD_TAR_URL"; then
            success=1
            break
        fi

        warn "连接 Steam 超时，3 秒后重试..."
        sleep 3
    done

    if [[ $success -eq 0 ]]; then
        rm -f "$tmp_file"
        die "SteamCMD 下载失败，请检查能否连接 Steam 服务器"
    fi

    info "下载完成，正在解压..."
    if ! tar -xzf "$tmp_file" -C "$STEAMCMD_DIR"; then
        rm -f "$tmp_file"
        die "解压 SteamCMD 失败，压缩包可能已损坏"
    fi

    rm -f "$tmp_file"
    info "SteamCMD 安装成功！"
}

# ============================================================
# DST 服务端下载 / 更新（含重试）
# ============================================================
update_dst_with_retry() {
    [[ -f "$STEAMCMD_DIR/steamcmd.sh" ]] || die "SteamCMD 未找到，无法更新"

    local max_attempts=5
    for ((i = 1; i <= max_attempts; i++)); do
        info "下载/更新 DST 服务端 (${i}/${max_attempts})..."

        "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$DST_ROOT" +login anonymous +app_info_update 1 +app_update 343050 validate +quit || true

        if [[ -f "$DST_BIN" ]]; then
            info "DST 服务端校验成功！"
            fix_dst_libs
            return 0
        fi

        warn "连接 Steam 超时，5 秒后重试..."

        info "清理 SteamCMD 缓存目录"
        rm -rf "$STEAMCMD_DIR/appcache"

        sleep 5
    done

    die "下载失败，请检查能否连接 Steam 服务器"
}

# ============================================================
# 修复 DST 所需的 32 位库文件
# ============================================================
fix_dst_libs() {
    mkdir -p "$DST_ROOT/bin/lib32"
    cp -f "$DST_ROOT/steamclient.so" "$DST_ROOT/bin/lib32/"
}

# ============================================================
# 部署游戏环境
# ============================================================
install_env() {
    # 已部署则跳过
    [[ -f "$DST_BIN" ]] && return 0

    local deploy_log="$HOME/deploy.log"

    # 清除旧日志信息
    : > "$deploy_log"

    exec > >(tee -a "$deploy_log") 2>&1

    info "检测到新环境，开始自动部署..."

    # ── 1/3 系统依赖 ──────────────────────────────────────────
    info "[1/3] 安装系统依赖..."
    sudo mkdir -p /etc/needrestart
    sudo tee /etc/needrestart/needrestart.conf &>/dev/null <<'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = -1;
$nrconf{verbosity} = 0;
EOF

    sudo add-apt-repository multiverse -y
    sudo dpkg --add-architecture i386
    sudo apt-get update || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libstdc++6:i386 libgcc1:i386 libcurl4-gnutls-dev:i386 ufw wget curl git screen ca-certificates

    # 放行端口
    configure_firewall

    # ── 2/3 SteamCMD ──────────────────────────────────────────
    info "[2/3] 安装 SteamCMD..."
    install_steamcmd

    # ── 3/3 DST 服务端 ────────────────────────────────────────
    info "[3/3] 下载/更新 DST 服务端..."
    update_dst_with_retry

    info "环境部署完成！"
}

# ============================================================
# 服务器进程管理
# ============================================================

# 查看 screen 会话是否存活
is_running() { screen -list | grep -q "$1"; }

# 监听启动日志
wait_for_startup() {
    local log_file="$1"
    local screen_name="$2"
    local timeout=10
    local count=0

    info "监视服务器启动状态..."

    # 等待日志加载
    while (( count < timeout )); do
        if ! is_running "$screen_name"; then
            cat "$log_file"
            die "进程 $screen_name 意外退出，可能原因: 端口未开放 / Token 无效 / Mod 配置错误"
        fi
        [[ -s "$log_file" ]] && break
        sleep 1
        (( count++ ))
    done

    [[ ! -s "$log_file" ]] && die "启动异常: ${timeout}s 内未检测到日志输出"

    info "日志已加载，等待世界生成..."

    while IFS= read -r line; do
        echo "$line"
        if echo "$line" | grep -q "is now connected"; then
            info "服务器启动成功！"
            pkill -P $$ tail 2>/dev/null || true
            return 0
        fi
    done < <(tail -n +1 -f "$log_file")
}

# ============================================================
# 初始化 / 启动 / 停止 / 更新 / 删除 / 查看运行状态
# ============================================================

# 初始化存档
init_cluster() {
    local slot="${1:-1}"
    local token="${2:-$DEFAULT_TOKEN}"
    local cluster_dir="$KLEI_DIR/Cluster_${slot}"

    if [[ ! -d "$cluster_dir" ]]; then
        info "存档 Cluster_${slot} 不存在，正在拉取默认存档..."
        mkdir -p "$KLEI_DIR"
        git clone --depth 1 "$GITHUB_REPO_URL" "$cluster_dir"
        rm -rf "$cluster_dir/.git"
        rm -rf "$cluster_dir/Master/save"
        rm -rf "$cluster_dir/Caves/save"
    fi

    info "写入 Cluster Token"
    echo "$token" > "$cluster_dir/cluster_token.txt"

    info "存档 Cluster_${slot} 初始化完成！"
}

# 启动服务器存档，start_server [1-5]
start_server() {
    local slot="${1:-1}"
    local log_file="$HOME/cluster${slot}.log"
    local dst_bin_dir="$DST_ROOT/bin"
    local cluster_dir="$KLEI_DIR/Cluster_${slot}"

    # 存档校验
    if [[ ! -d "$cluster_dir" ]]; then
        die "存档 Cluster_${slot} 不存在，请先执行 init 命令初始化存档"
    fi

    # 避免重复启动
    if is_running "master${slot}"; then
        warn "Master${slot} 已运行，请勿重复启动"
        return 0
    fi

    # 清除旧日志信息
    : > "$log_file"

    # 切换目录
    cd "$DST_ROOT/bin"

    # 启动 Master
    info "启动 Master${slot}..."
    screen -dmS "master${slot}" bash -c "$DST_BIN -console -cluster Cluster_${slot} -shard Master | sed 's/^/Master: /' > ${log_file} 2>&1"

    # 预热等待
    info "等待 Master 预热(15s)..."
    for (( i = 1; i <= 15; i++ )); do
        if ! is_running "master${slot}"; then
            cat "$log_file"
            die "Master 在预热期间意外退出"
        fi
        sleep 1
    done

    # 启动 Caves
    info "启动 Caves${slot}..."
    screen -dmS "caves${slot}" bash -c "$DST_BIN -console -cluster Cluster_${slot} -shard Caves | sed 's/^/Caves: /' >> ${log_file} 2>&1"

    wait_for_startup "$log_file" "master${slot}"
}

# 停止服务器存档，stop_server [1-5]
stop_server() {
    local slot="${1:-1}"

    if ! is_running "master${slot}"; then
        warn "Master${slot} 未运行"
        return 0
    fi

    info "正在停止 Cluster_${slot}..."

    # 游戏内公告倒计时
    screen -S "master${slot}" -X stuff 'c_announce("服务器将在5秒后关闭...")\n'
    sleep 1
    for i in 5 4 3 2 1; do
        screen -S "master${slot}" -X stuff "c_announce(\"${i}\")\n"
        sleep 1
    done

    # 发送关机指令
    screen -S "caves${slot}" -X stuff 'c_shutdown(true)\n' 2>/dev/null || true
    screen -S "master${slot}" -X stuff 'c_shutdown(true)\n' 2>/dev/null || true

    # 等待进程退出
    info "等待进程退出..."
    local retry=0
    while is_running "master${slot}"; do
        sleep 1
        (( ++retry ))
        if (( retry > 10 )); then
            warn "进程未响应，将强制停止"
            screen -S "caves${slot}" -X quit 2>/dev/null || true
            screen -S "master${slot}" -X quit 2>/dev/null || true
            break
        fi
    done

    info "Cluster_${slot} 已停止！"
}

# 检查游戏版本并自动更新
update_server() {
    if is_running "master"; then
        warn "请先停止所有运行中的服务器再执行更新"
        return 0
    fi

    info "正在检查 DST 服务端是否有新版本..."

    # 获取本地 Build ID
    local manifest_file="$DST_ROOT/steamapps/appmanifest_343050.acf"
    local local_build_id="0"
    if [[ -f "$manifest_file" ]]; then
        local_build_id=$(grep -i '"buildid"' "$manifest_file" | grep -oP '"\K[0-9]+(?=")' | head -n 1)
        local_build_id="${local_build_id:-0}"
    fi

    # 获取远程最新 Build ID
    local remote_build_id
    remote_build_id=$(curl -s --connect-timeout 5 "https://api.steamcmd.net/v1/info/343050" | grep -oP '"public":\s*\{[^}]*\}' | grep -oP '"buildid"\s*:\s*"\K[0-9]+' | head -n 1)
    remote_build_id="${remote_build_id:-0}"

    # 校验远程结果合法性
    if ! [[ "$remote_build_id" =~ ^[0-9]+$ && "$remote_build_id" != "0" ]]; then
        warn "获取 Steam 最新版本信息失败，将执行强制更新..."
        update_dst_with_retry
        info "强制更新校验完成！"
        return 0
    fi

    # 对比版本
    if [[ "$local_build_id" == "$remote_build_id" ]]; then
        info "当前已是最新版本 (Build ID: ${local_build_id})，无需更新"
    else
        info "发现新版本(本地: ${local_build_id} -> 最新: ${remote_build_id}), 开始下载更新..."
        update_dst_with_retry
        info "更新完成！"
    fi
}

# 删除服务器存档，delete_server [1-5]
delete_server() {
    local slot="${1:-1}"
    local cluster_dir="$KLEI_DIR/Cluster_${slot}"
    local log_file="$HOME/cluster${slot}.log"

    info "准备删除存档 Cluster_${slot} ..."

    # 如果存档正在运行，将强制停止
    if is_running "master${slot}"; then
        warn "检测到存档正在运行，将强制停止..."
        stop_server "$slot"
    fi

    # 删除存档目录
    if [[ -d "$cluster_dir" ]]; then
        rm -rf "$cluster_dir"
        info "已删除存档文件: $cluster_dir"
    else
        warn "存档目录不存在，无需删除"
    fi

    # 清理日志文件
    [[ -f "$log_file" ]] && rm -f "$log_file"

    info "存档 Cluster_${slot} 已删除！"
}

# 查看存档运行状态，check_status [1-5]
check_status() {
    local slot="${1:-1}"
    local master_screen="master${slot}"
    local caves_screen="caves${slot}"
    local status_str=""

    # 查看运行状态
    if is_running "$master_screen"; then
        status_str="运行中 (Running)"
    else
        status_str="已停止 (Stopped)"
    fi

    info "存档 Cluster_${slot} 的状态: ${status_str}"

    if is_running "$master_screen"; then
        echo "RUNNING"
    else
        echo "STOPPED"
    fi
}

# ============================================================
# 交互菜单
# ============================================================
show_menu() {
    clear
    echo "================================="
    echo -e "${C_GREEN}     DST 饥荒服务器管理面板${C_RESET}"
    echo "================================="
    echo "  1. 初始化存档"
    echo "  2. 启动服务器存档"
    echo "  3. 停止服务器存档"
    echo "  4. 检查更新"
    echo "  5. 删除服务器存档"
    echo "  6. 查看存档运行状态"
    echo "  7. 退出"
    echo "---------------------------------"
    read -rp "请选择 [1-7]: " choice

    case "$choice" in
        1) init_cluster  ;;
        2) start_server  ;;
        3) stop_server   ;;
        4) update_server ;;
        5) delete_server ;;
        6) check_status  ;;
        7) exit 0 ;;
        *) warn "无效选项，请重新输入" ;;
    esac

    read -rp "按回车继续..."
}

# ============================================================
# 入口
# ============================================================
main() {
    if [[ "$(whoami)" != "$TARGET_USER" ]]; then

        # 检查系统版本
        check_os_version

        # 查看当前用户是否是 root 或是否具有 sudo 权限
        if [[ "$(id -u)" -ne 0 ]]; then
            if ! command -v sudo &>/dev/null || ! sudo -n true &>/dev/null; then
                die "请使用 root 用户或具有 sudo 权限的用户执行此脚本"
            fi
        fi

        # 3. 创建 charles 用户并切换身份
        bootstrap_user "$@"
    fi

    # 以下均在 charles 用户下执行
    if [[ $# -gt 0 ]]; then
        # ── 自动化模式（CI / 脚本调用）──────────────────────
        case "$1" in
            deploy) install_env ;;
            init)   init_cluster  "${2:-1}" "${3:-}" ;;
            start)  start_server  "${2:-1}" ;;
            stop)   stop_server   "${2:-1}" ;;
            update) update_server ;;
            delete) delete_server "${2:-1}" ;;
            status) check_status  "${2:-1}" ;;
            *)
                echo "用法: $0 [deploy|init|start|stop|update|delete|status] [1-5] [token]"
                exit 1
                ;;
        esac
    else
        # ── 交互模式 ─────────────────────────────────────────
        install_env
        while true; do
            show_menu
        done
    fi
}

main "$@"
