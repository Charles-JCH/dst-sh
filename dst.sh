#!/bin/bash
# ============================================================
#   DST 饥荒联机版 服务器一键管理脚本
#   Author : Charles
#   功能   : 部署 / 启动 / 停止 / 更新
# ============================================================
set -euo pipefail

# ============================================================
# 颜色 & 日志
# ============================================================
readonly RED="\033[1;31m"
readonly GREEN="\033[1;32m"
readonly YELLOW="\033[1;33m"
readonly BLUE="\033[1;34m"
readonly RESET="\033[0m"

log()   { echo -e "${GREEN}>>> [系统]${RESET} $*"; }
warn()  { echo -e "${YELLOW}>>> [警告]${RESET} $*"; }
error() { echo -e "${RED}>>> [错误]${RESET} $*"; }

# 遇到不可恢复错误时打印并退出
die() { error "$*"; exit 1; }

# ============================================================
# 全局常量
# ============================================================
readonly TARGET_USER="charles"
readonly TARGET_PASS="123456"

readonly DST_ROOT="$HOME/dst"
readonly DST_BIN="$DST_ROOT/bin/dontstarve_dedicated_server_nullrenderer"
readonly STEAMCMD_ROOT="$HOME/steamcmd"
readonly KLEI_ROOT="$HOME/.klei/DoNotStarveTogether"
readonly GITHUB_REPO_URL="https://github.com/Charles-JCH/dst.git"
readonly DEFAULT_TOKEN="pds-g^KU_XKeqpZXq^rtM08d2qtiy34ZRzi1P2wTLmrzTK3AcmnnMRePnXDjo="

# 需要开放的 UDP 端口（空格分隔）
readonly DST_PORTS="10888 10999 10998"

# ============================================================
# 权限引导（root → charles）
# ============================================================
bootstrap_user() {
    log "检测到 Root 用户，正在切换至 '$TARGET_USER'..."

    # 创建用户（不存在时）
    if ! id "$TARGET_USER" &>/dev/null; then
        log "创建用户: $TARGET_USER"
        useradd -m -s /bin/bash "$TARGET_USER"
        echo "$TARGET_USER:$TARGET_PASS" | chpasswd
        log "用户密码: $TARGET_PASS"
    fi

    # 配置 sudo 免密
    local sudoers_file="/etc/sudoers.d/$TARGET_USER"
    if [[ ! -f "$sudoers_file" ]]; then
        log "配置 sudo 免密权限..."
        command -v sudo &>/dev/null || apt-get install -y sudo
        echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
        chmod 0440 "$sudoers_file"
    fi

    # 复制脚本到目标用户目录
    local script_name
    script_name=$(basename "$0")
    local target_script="/home/$TARGET_USER/$script_name"
    cp "$0" "$target_script"
    chown "$TARGET_USER:$TARGET_USER" "$target_script"
    chmod +x "$target_script"

    log "切换身份，重新执行..."
    local safe_args
    safe_args=$(printf '%q ' "$@")
    exec su - "$TARGET_USER" -c "bash $target_script $safe_args"
}

# ============================================================
# 防火墙配置
# ============================================================
configure_firewall() {
    log "检测防火墙配置..."

    if ! command -v ufw &>/dev/null; then
        warn "未检测到 ufw，跳过自动配置。"
        warn "请手动开放 UDP 端口: $DST_PORTS"
        return 0
    fi

    if ! sudo ufw status | grep -q "Status: active"; then
        warn "ufw 未启用，如遇连接问题请执行: sudo ufw enable"
    fi

    # 放行 SSH
    sudo ufw allow 22/tcp
    log "已放行端口 22/tcp (SSH)"

    # 放行 DST 端口
    for port in $DST_PORTS; do
        sudo ufw allow "$port/udp"
        log "已放行端口 $port/udp"
    done
}

# ============================================================
# SteamCMD 安装
# ============================================================
install_steamcmd() {
    [[ -f "$STEAMCMD_ROOT/steamcmd.sh" ]] && return 0

    log "安装 SteamCMD..."
    mkdir -p "$STEAMCMD_ROOT"
    wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -zxf - -C "$STEAMCMD_ROOT"
}

# ============================================================
# DST 服务端下载 / 更新（含重试）
# ============================================================
update_dst_with_retry() {
    [[ -f "$STEAMCMD_ROOT/steamcmd.sh" ]] || die "SteamCMD 未找到，无法更新！"

    local max_attempts=5
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        log "下载/更新 DST 服务端 (${attempt}/${max_attempts})..."

        "$STEAMCMD_ROOT/steamcmd.sh" +force_install_dir "$DST_ROOT" +login anonymous +app_info_update 1 +app_update 343050 validate +quit || true

        if [[ -f "$DST_BIN" ]]; then
            log "DST 服务端校验成功！"
            _fix_dst_libs
            return 0
        fi

        warn "连接 Steam 超时，5 秒后重试..."
        
        log "清理 SteamCMD 损坏的缓存目录..."
        rm -rf "$STEAMCMD_ROOT/appcache"
        
        sleep 5
    done

    die "下载失败，请检查能否连接 Steam 服务器。"
}

# 修复 DST 所需的 32 位库文件
_fix_dst_libs() {
    mkdir -p "$DST_ROOT/bin/lib32"
    cp -f "$DST_ROOT/steamclient.so" "$DST_ROOT/bin/lib32/"
}

# ============================================================
# 环境部署（首次运行时自动执行）
# ============================================================
install_env() {
    # 已部署则跳过
    [[ -f "$DST_BIN" ]] && return 0

    local deploy_log="$HOME/deploy.log"
    : > "$deploy_log"
    exec > >(tee -a "$deploy_log") 2>&1

    log "检测到新环境，开始自动部署..."

    # ── 1/3 系统依赖 ──────────────────────────────────────────
    log "[1/3] 安装系统依赖..."
    sudo mkdir -p /etc/needrestart
    sudo tee /etc/needrestart/needrestart.conf &>/dev/null <<'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = -1;
$nrconf{verbosity} = 0;
EOF

    sudo DEBIAN_FRONTEND=noninteractive add-apt-repository multiverse -y
    sudo DEBIAN_FRONTEND=noninteractive dpkg --add-architecture i386
    sudo DEBIAN_FRONTEND=noninteractive apt-get update || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libstdc++6:i386 libgcc1:i386 libcurl4-gnutls-dev:i386 screen git ufw

    configure_firewall

    # ── 2/3 SteamCMD ──────────────────────────────────────────
    log "[2/3] 安装 SteamCMD..."
    install_steamcmd

    # ── 3/3 DST 服务端 ────────────────────────────────────────
    log "[3/3] 下载/更新 DST 服务端..."
    update_dst_with_retry

    log "环境部署完成！"
}

# ============================================================
# 存档管理
# ============================================================

# 初始化存档
init_cluster() {
    local slot="$1"
    local token="${2:-$DEFAULT_TOKEN}"
    local cluster_dir="$KLEI_ROOT/Cluster_${slot}"

    if [[ ! -d "$cluster_dir" ]]; then
        log "存档 Cluster_${slot} 不存在，正在拉取默认存档..."
        mkdir -p "$KLEI_ROOT"
        git clone --depth 1 "$GITHUB_REPO_URL" "$cluster_dir"
        rm -rf "$cluster_dir/.git"
    fi

    log "写入 Cluster Token..."
    echo "$token" > "$cluster_dir/cluster_token.txt"

    echo "$cluster_dir"
    log "存档 Cluster_${slot} 初始化完成！"
}

# ============================================================
# 服务器进程管理
# ============================================================

# 检查指定 screen 会话是否存活
is_running() { screen -list | grep -q "$1"; }

# 等待服务器启动并监控日志
# 参数: <log_file> <master_screen_name>
wait_for_startup() {
    local log_file="$1"
    local screen_name="$2"
    local timeout=10
    local count=0

    log "监视服务器启动状态..."

    # 等待日志文件出现内容
    while (( count < timeout )); do
        if ! is_running "$screen_name"; then
            error "进程 ($screen_name) 意外退出！"
            error "可能原因：Mod 配置错误 / Token 无效 / 端口未开放"
            [[ -f "$log_file" ]] && cat "$log_file"
            return 1
        fi
        [[ -s "$log_file" ]] && break
        sleep 1
        (( count++ ))
    done

    if [[ ! -s "$log_file" ]]; then
        error "启动异常：${timeout}s 内未检测到日志输出"
        return 1
    fi

    # 实时跟踪日志，直到看到连接成功
    log "日志已建立，等待世界生成..."
    while IFS= read -r line; do
        echo "$line"
        if echo "$line" | grep -q "is now connected"; then
            log "服务器启动成功！"
            pkill -P $$ tail 2>/dev/null || true
            return 0
        fi
    done < <(tail -n +1 -f "$log_file")
}

# ============================================================
# 对外命令：启动 / 停止 / 更新
# ============================================================

# 启动服务器
# 用法: start_server [1-5]
start_server() {
    local slot="${1:-1}"
    local log_file="$HOME/cluster${slot}.log"
    local dst_bin_dir="$DST_ROOT/bin"
    local cluster_dir="$KLEI_ROOT/Cluster_${slot}"

    # 存档初始化校验
    if [[ ! -d "$cluster_dir" ]]; then
        die "存档 Cluster_${slot} 不存在！请先执行 init 命令初始化存档。"
    fi

    # 避免重复启动
    if is_running "master${slot}"; then
        warn "Master${slot} 已在运行，请勿重复启动。"
        return 0
    fi

    : > "$log_file"
    cd "$dst_bin_dir"

    # 启动 Master
    log "启动 Master${slot}..."
    screen -dmS "master${slot}" bash -c "./dontstarve_dedicated_server_nullrenderer -console -cluster Cluster_${slot} -shard Master | sed 's/^/Master: /' > ${log_file} 2>&1"

    # 预热等待
    log "等待 Master 预热（15s）..."
    for (( i = 1; i <= 15; i++ )); do
        if ! is_running "master${slot}"; then
            error "Master 在预热期间意外退出！"
            cat "$log_file"
            return 1
        fi
        sleep 1
    done

    # 启动 Caves
    log "启动 Caves${slot}..."
    screen -dmS "caves${slot}" bash -c "./dontstarve_dedicated_server_nullrenderer -console -cluster Cluster_${slot} -shard Caves | sed 's/^/Caves: /' >> ${log_file} 2>&1"

    wait_for_startup "$log_file" "master${slot}"
}

# 停止服务器
# 用法: stop_server [1-5]
stop_server() {
    local slot="${1:-1}"

    if ! is_running "master${slot}"; then
        warn "Master${slot} 未在运行。"
        return 0
    fi

    log "正在关闭 Cluster_${slot}..."

    # 游戏内公告倒计时
    screen -S "master${slot}" -X stuff 'c_announce("服务器将在5秒后关闭")\n'
    sleep 1
    for i in 5 4 3 2 1; do
        screen -S "master${slot}" -X stuff "c_announce(\"${i}\")\n"
        sleep 1
    done

    # 发送关机指令
    screen -S "caves${slot}"  -X stuff 'c_shutdown(true)\n'
    screen -S "master${slot}" -X stuff 'c_shutdown(true)\n'

    # 等待进程退出
    log "等待进程退出..."
    local retry=0
    while is_running "master${slot}"; do
        sleep 1
        (( retry++ ))
        if (( retry > 10 )); then
            warn "进程未响应，强制终止..."
            screen -S "master${slot}" -X quit 2>/dev/null || true
            screen -S "caves${slot}"  -X quit 2>/dev/null || true
            break
        fi
    done

    log "Cluster_${slot} 已停止。"
}

# 检查游戏版本并自动更新
update_server() {
    if is_running "master"; then
        warn "请先停止所有运行中的服务器再执行更新。"
        return 0
    fi

    log "正在检查 DST 服务端是否有新版本..."

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
        warn "获取 Steam 最新版本信息失败，将强制执行更新校验流程..."
        update_dst_with_retry
        log "强制更新校验完成。"
        return
    fi

    # 对比版本
    if [[ "$local_build_id" == "$remote_build_id" ]]; then
        log "当前已是最新版本 (Build ID: ${local_build_id})，无需更新！"
    else
        log "发现新版本！(本地: ${local_build_id} -> 最新: ${remote_build_id})"
        log "开始下载更新..."
        update_dst_with_retry
        log "更新完成！"
    fi
}

# ============================================================
# 交互菜单
# ============================================================
show_menu() {
    clear
    echo "================================="
    echo -e "${GREEN}     DST 饥荒服务器管理面板${RESET}"
    echo "================================="
    echo "  1. 初始化存档"
    echo "  2. 启动服务器"
    echo "  3. 停止服务器"
    echo "  4. 检查更新"
    echo "  5. 退出"
    echo "---------------------------------"
    read -rp "请选择 [1-5]: " choice

    case "$choice" in
        1) init_cluster 1 ;;
        2) start_server 1 ;;
        3) stop_server  1 ;;
        4) update_server  ;;
        5) exit 0 ;;
        *) warn "无效选项，请重新输入。" ;;
    esac

    read -rp "按回车继续..."
}

# ============================================================
# 入口
# ============================================================
main() {
    # root 用户：引导切换到普通用户
    if [[ "$(id -u)" -eq 0 ]]; then
        bootstrap_user "$@"
        # bootstrap_user 调用 exec，不会继续执行
    fi

    # 以下均在 charles 用户下执行
    if [[ $# -gt 0 ]]; then
        # ── 自动化模式（CI / 脚本调用）──────────────────────
        case "$1" in
            deploy) install_env ;;
            init)   init_cluster "${2:-1}" "${3:-}" ;;
            start)  start_server "${2:-1}" ;;
            stop)   stop_server  "${2:-1}" ;;
            update) update_server ;;
            *)
                echo "用法: $0 [deploy|init|start|stop|update] [1-5] [token]"
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
