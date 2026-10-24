#!/usr/bin/env bash

# stdin 处理（安全版，原 `exec </dev/tty` 在 curl|bash 下是灾难）：
# - curl|bash 时脚本本身从 stdin 读取，此时绝不能 exec </dev/tty，
#   否则 bash 会从键盘继续读"脚本剩余部分"：后面 1500 行永不执行，且用户击键会被当成命令执行
# - 文件运行但 stdin 非 tty 时，重定向到 /dev/tty 保证 read 正常
# 注意：[ -c /dev/tty ] 只检查设备节点是否存在（Linux 上永远存在），不能判断 open() 是否成功；
#       必须在子 shell 里试探 open，失败才走报错分支（exec 重定向失败默认不会终止脚本）
if [ ! -t 0 ]; then
    if [ -z "${BASH_SOURCE[0]}" ]; then
        echo "错误：检测到通过管道运行（如 curl | bash），本脚本需要交互式输入，无法继续。" >&2
        echo "请改用：curl -fsSL <脚本URL> -o mimi.sh && bash mimi.sh" >&2
        exit 1
    fi
    if (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty
    else
        echo "错误：需要交互式终端（无 /dev/tty），请在终端中运行。" >&2
        exit 1
    fi
fi

gl_bai=$'\033[0m'; gl_lv=$'\033[32m'; gl_huang=$'\033[33m'; gl_hui=$'\033[90m'; gl_red=$'\033[31m'; gl_kjlan=$'\033[36m'
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="${gl_kjlan}"
SB_CONF_LOCK="/var/lock/sing-box-config.lock"
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
META_DIR="/etc/sing-box/meta"
SYSCTL_CONF="/etc/sysctl.d/99-yw-optimize.conf"
MODE_FILE="/etc/yw_sysctl_mode"
# 出厂快照（标准/高级模式共用一份，模式切换不删除）
FACTORY_SNAPSHOT="/etc/sysctl.d/.yw_factory_snapshot"

# 高级调优独立配置 (互不干扰)
ADV_SYSCTL_CONF="/etc/sysctl.d/99-yw-adv-optimize.conf"
ADV_MODE_FILE="/etc/yw_adv_sysctl_mode"

mkdir -p /var/lock 2>/dev/null
mkdir -p "$META_DIR" 2>/dev/null

# 校验日志用 mktemp，避免固定 /tmp 路径的 symlink 攻击与并发互踩
CHECK_LOG="$(mktemp /tmp/.yw_checklog.XXXXXX 2>/dev/null || echo /tmp/.yw_checklog.$$)"
trap 'rm -f "$CHECK_LOG"' EXIT

# URL 编码（节点名拼链接时用，字节级处理，兼容中文）
urlencode() {
    local s=$1 i c o="" hex
    local LC_ALL=C
    for (( i=0; i<${#s}; i++ )); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) o+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; o+="$hex" ;;
        esac
    done
    printf '%s' "$o"
}

# 容器环境（OpenVZ/LXC）下 /proc/sys 可能只读，提前说明，避免用户误以为脚本坏了
warn_container_ro() {
    local virt
    virt=$(systemd-detect-virt 2>/dev/null)
    case "$virt" in
        lxc|openvz)
            echo -e "${Y}提示：检测到容器环境(${virt})，部分内核参数可能只读，写入失败属正常现象${R}"
            ;;
    esac
}
# 只读探测 sysctl 配置文件里的 key 是否存在（不改内核），缺失则返回非 0
# 把出厂快照中有、但本次配置没写的 key 恢复为出厂值，避免模式切换后旧值残留
restore_unmanaged_keys() {
    local conf=$1 key val
    [ -f "$FACTORY_SNAPSHOT" ] || return 0
    local managed
    managed=$(sed -e 's/#.*//' "$conf" | grep '=' | cut -d= -f1 | xargs -n1 | sort -u)
    while IFS='=' read -r key val || [ -n "$key" ]; do
        [[ "$key" =~ ^# ]] && continue
        [ -z "$key" ] && continue
        key=$(echo "$key" | xargs); val=$(echo "$val" | xargs)
        echo "$managed" | grep -qx "$key" && continue
        sysctl -w "$key=$val" >/dev/null 2>&1
    done < "$FACTORY_SNAPSHOT"
}

# 禁用 IPv6 的机器上 listen :: 会 bind 失败，自动降级为 0.0.0.0
sb_listen_addr() {
    if ! command -v ip >/dev/null 2>&1; then
        echo "::"
    elif ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${R}"; exit 1; }; }

check_env() {
    root_use
    local need_update=0
    # sed 用于 auto_shortcut 的 trap 组合解析、apply_advanced_optimize 等多处文本处理
    # 缺失会导致旧 trap 清理动作丢失（CHECK_LOG 残留）和残留列表打印残缺
    for cmd in curl wget jq openssl iptables ip6tables tar ip ss shuf sed; do
        command -v $cmd >/dev/null 2>&1 || need_update=1
    done
    if [ "$need_update" -eq 1 ]; then
        echo -e "${Y}正在准备基础环境...${R}"
        export DEBIAN_FRONTEND=noninteractive
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y
            apt-get install -y curl wget jq openssl iptables tar iproute2 procps coreutils iptables-persistent gnupg ca-certificates sed
        elif command -v yum >/dev/null 2>&1; then
            yum update -y
            yum install -y curl wget jq openssl iptables tar iproute procps-ng coreutils iptables-services sed
        elif command -v dnf >/dev/null 2>&1; then
            dnf update -y
            dnf install -y curl wget jq openssl iptables tar iproute procps-ng coreutils iptables-services sed
        fi
        
        # 安装后全量校验：清单与上方触发清单完全一致（base64 在主脚本中未使用，已剔除）
        local missing=""
        for cmd in curl wget jq openssl iptables ip6tables tar ip ss shuf sed; do
            command -v $cmd >/dev/null 2>&1 || missing="$missing $cmd"
        done
        if [ -n "$missing" ]; then
            echo -e "${RED}错误：以下依赖安装失败：${missing}，请手动安装后重试。${R}"
            exit 1
        fi
        echo -e "${G}✅ 基础环境准备完毕！${R}"
    fi
    echo -e "${Y}正在同步系统时间...${R}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable systemd-timesyncd >/dev/null 2>&1
        systemctl restart systemd-timesyncd >/dev/null 2>&1
    fi
    timedatectl set-ntp true >/dev/null 2>&1
    sleep 2
}

# 内网 IP 段：NAT 机器上 ip route get 拿到的是内网 IP，生成的节点链接不可用，直接丢弃
is_private_ip() {
    local ip=$1
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[78][0-9]|9[0-9]|1[0-1][0-9]|12[0-7])\. ]] && return 0  # CGNAT 100.64.0.0/10
    [[ "$ip" =~ ^169\.254\. ]] && return 0  # 链路本地 169.254.0.0/16
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^0\. ]] && return 0
    return 1
}
get_my_ip() {
    local server_ip
    server_ip=$(curl -s4 --max-time 6 https://api4.ipify.org 2>/dev/null)
    # 校验：必须是单行合法 IPv4（防止错误页 HTML 或多行响应拼进节点链接）
    # 用 _is_valid_ipv4 严格校验：每段 0-255、拒绝前导零（010 等）
    _is_valid_ipv4() {
        local ip="$1"
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
        local IFS=.
        local -a segs=($ip)
        [ ${#segs[@]} -eq 4 ] || return 1
        local s
        for s in "${segs[@]}"; do
            # 拒绝前导零（010 等，与标准 inet_aton 不同，避免歧义）
            # 单独的 0 合法，但 010 等同于 8（八进制），不可接受
            [[ "$s" =~ ^0[0-9]+$ ]] && return 1
            [ "$s" -ge 0 ] 2>/dev/null && [ "$s" -le 255 ] 2>/dev/null || return 1
        done
        return 0
    }
    if ! _is_valid_ipv4 "$server_ip"; then
        server_ip=""
    fi
    if [ -z "$server_ip" ]; then
        server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}')
        # 同样校验回退路径拿到的 IP
        if ! _is_valid_ipv4 "$server_ip"; then
            server_ip=""
        fi
    fi
    is_private_ip "$server_ip" && server_ip=""
    echo "$server_ip"
}

ask_reboot() {
    # read 失败（EOF/Ctrl+D）时直接走默认"不重启"分支，不当作"是"
    if ! read -r -e -p "是否立即重启服务器以应用新内核？[Y/n]: " rb; then
        echo -e "${Y}已跳过重启（输入 EOF），请稍后手动执行 reboot 命令。${R}"
        return
    fi
    if [[ "$rb" =~ ^[Yy]$|^$ ]]; then
        echo -e "${Y}系统将在 3 秒后重启...${R}"
        sleep 3
        reboot
    else
        echo -e "${Y}已跳过重启，请稍后手动执行 reboot 命令。${R}"
    fi
}

# ================= 标准网络与内核优化 =================
take_factory_snapshot() {
    if [ -f "$FACTORY_SNAPSHOT" ]; then
        return 0
    fi
    # 升级兼容：旧版（v1）的标准/高级快照若存在则迁移，避免把旧调优值误拍成"出厂"
    local legacy=""
    for f in /etc/sysctl.d/.yw_std_snapshot /etc/sysctl.d/.yw_adv_snapshot; do
        if [ -f "$f" ]; then legacy="$f"; break; fi
    done
    if [ -n "$legacy" ]; then
        cp -f "$legacy" "$FACTORY_SNAPSHOT"
        rm -f /etc/sysctl.d/.yw_std_snapshot /etc/sysctl.d/.yw_adv_snapshot
        echo -e "${Y}检测到旧版快照，已迁移为统一出厂快照：${legacy}${R}"
        echo -e "${Y}注意：若旧快照拍摄于调优之后，还原值可能并非真正的出厂值${R}"
        return 0
    fi
    echo -e "${Y}首次使用网络优化，正在备份出厂网络参数...${R}"
    echo -e "${Y}注意：若此前运行过其他调优脚本（如 teddysun bbr.sh），当前值可能已非真正出厂值，快照将据此还原${R}"
    {
        echo "# MiMi 出厂快照 $(date)"
        for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding \
                 net.core.default_qdisc net.ipv4.tcp_congestion_control \
                 net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_ecn \
                 fs.file-max net.core.somaxconn \
                 net.core.rmem_max net.core.wmem_max \
                 net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
                 net.ipv4.tcp_syncookies net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout \
                 net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min net.ipv4.udp_mem \
                 net.core.netdev_max_backlog; do
            echo "$k = $(sysctl -n "$k" 2>/dev/null)"
        done
    } > "$FACTORY_SNAPSHOT"
    echo -e "${G}出厂快照已保存至 ${FACTORY_SNAPSHOT}${R}"
}

apply_optimize() {
    local mode=$1
    warn_container_ro
    local mode_name=$2
    echo -e "${Y}切换到${mode_name}...${R}"
    echo -e "${Y}写入优化配置...${R}"
    
    # 清理高级调优的配置，防止冲突（出厂快照保留，跨模式共用）
    rm -f "$ADV_SYSCTL_CONF" "$ADV_MODE_FILE" 2>/dev/null

    # 优化前先备份出厂状态，用于还原
    take_factory_snapshot

    # 直播模式的 UDP 内存阈值按物理内存等比推导（原写死值约为 4GB 机器的量级）
    local mem_kb=$(awk '/MemTotal:/{print $2}' /proc/meminfo)
    local pages_total=$(( mem_kb / 4 ))
    local u_min=$(( pages_total * 379008 / 1048576 ))
    [ "$u_min" -lt 16384 ] && u_min=16384
    [ "$u_min" -gt 1048576 ] && u_min=1048576
    local u_pressure=$(( u_min * 4 / 3 ))
    local u_max=$(( u_min * 2 ))

    # BBR/fq 可用性探测（与高级模式一致）：不支持的内核回退，避免写死值导致每行写入失败
    modprobe tcp_bbr 2>/dev/null
    local new_cc="bbr"
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo -e "${Y}内核不支持 BBR，回退到 cubic${R}"
        new_cc="cubic"
    fi
    local new_qd="fq"
    local orig_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        echo -e "${Y}内核不支持 fq，回退到 fq_codel${R}"
        new_qd="fq_codel"
    fi
    # 探测本身是一次内核写入，恢复原值以保无副作用，后续由统一应用流程写入
    [ -n "$orig_qd" ] && sysctl -w net.core.default_qdisc="$orig_qd" >/dev/null 2>&1

    if [ "$mode" == "balance" ]; then
        cat > "$SYSCTL_CONF" << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = $new_qd
net.ipv4.tcp_congestion_control = $new_cc
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 1000000
net.core.somaxconn = 32768
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
EOF
    elif [ "$mode" == "live" ]; then
        cat > "$SYSCTL_CONF" << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = $new_qd
net.ipv4.tcp_congestion_control = $new_cc
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 1000000
net.core.somaxconn = 32768
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = $u_min $u_pressure $u_max
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
EOF
    fi

    # 检查配置文件是否真写进去：路径被占成目录、磁盘满、权限不足时 cat 会失败但 bash 不报错
    # 回读校验：写完文件应非空且至少包含一个 '='（key=value 行）
    if [ ! -s "$SYSCTL_CONF" ] || ! grep -q '=' "$SYSCTL_CONF" 2>/dev/null; then
        echo -e "${RED}❌ 写入 $SYSCTL_CONF 失败（可能路径被占用、磁盘满或权限不足）${R}" >&2
        echo -e "${RED}   参数未落盘，重启后不会生效。请检查 $SYSCTL_CONF 路径后重试${R}" >&2
        return 1
    fi

    echo -e "${Y}应用优化参数...${R}"
    # 逐 key 应用并精确计数：sysctl -p 的输出格式不统一（Invalid argument 等失败行既无 = 也无 cannot stat），grep 计数会虚高/漏报
    local applied=0 failed=0 skipped=0
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        k=$(echo "$k" | xargs); v=$(echo "$v" | xargs)
        [ -z "$k" ] && continue
        # 存在性检查：ipv6.disable=1 等场景下 key 根本不存在（如 net.ipv6.*），
        # 计为跳过（不计失败），并从持久化配置中剔除，避免每次开机 sysctl --system 报错
        if [ ! -f "/proc/sys/${k//.//}" ]; then
            ((skipped++))
            sed -i "/^${k//./\\.}[[:space:]]*=/d" "$SYSCTL_CONF"
            continue
        fi
        if LC_ALL=C sysctl -w "$k=$v" >/dev/null 2>&1; then
            ((applied++))
        else
            ((failed++))
            # 写入失败的 key 同样从持久化配置剔除，避免每次开机 sysctl --system 报错刷屏
            sed -i "/^${k//./\\.}[[:space:]]*=/d" "$SYSCTL_CONF"
        fi
    done < "$SYSCTL_CONF"

    # 模式标记在应用之后写；applied=0（一个都没应用上，如只读容器）时不写，避免菜单显示与实际不符
    [ "$applied" -gt 0 ] && echo "$mode_name" > "$MODE_FILE"

    echo -e "${G}已应用 ${applied} 项参数${R}"
    [ "$skipped" -gt 0 ] && echo -e "${Y}跳过 ${skipped} 项本内核不存在的参数${R}"
    [ "$failed" -gt 0 ] && echo -e "${Y}失败 ${failed} 项只读/不支持的参数（已从持久化配置中剔除）${R}"
    
    # 本次配置没覆盖的 key 恢复出厂值，避免从其他模式切换后旧值残留
    restore_unmanaged_keys "$SYSCTL_CONF"
    
    local mem=$(free -m | awk '/Mem:/{print $2}')
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "内存: ${mem}MB | 拥塞算法: ${cc} | 队列: ${qdisc}"
    echo -e "${Y}提示：网络参数已变更，若出现终端卡顿或断开，请重新连接 SSH 即可。${R}"
    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}${mode_name} 未完全应用（${failed} 项参数失败）${R}"
        return 1
    fi
    echo -e "${G}${mode_name} 优化完成！配置已持久化到 ${SYSCTL_CONF}${R}"
}

restore_default() {
    echo -e "${Y}还原默认设置...${R}"
    rm -f "$SYSCTL_CONF" "$MODE_FILE"
    rm -f "$ADV_SYSCTL_CONF" "$ADV_MODE_FILE" # 同时清理高级调优（出厂快照保留用于还原）
    
    # 优先从快照精准还原 (内核即时生效，无需重启)
    if [ -f "$FACTORY_SNAPSHOT" ]; then
        echo -e "${Y}检测到出厂快照，正在精准还原...${R}"
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^# ]] && continue
            [ -z "$key" ] && continue
            key=$(echo "$key" | xargs); val=$(echo "$val" | xargs)
            sysctl -w "$key=$val" >/dev/null 2>&1
        done < "$FACTORY_SNAPSHOT"
        rm -f "$FACTORY_SNAPSHOT"
        echo -e "${G}✅ 已按出厂快照精准还原网络配置${R}"
    else
        # 无快照时的兜底策略 (部分参数需重启才完全生效)
        echo -e "${Y}未找到出厂快照，应用系统默认配置...${R}"
        sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/default_qdisc/d' /etc/sysctl.conf
        
        echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq_codel" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    local mem=$(free -m | awk '/Mem:/{print $2}')
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "${G}已还原系统默认网络配置${R}"
    echo -e "内存: ${mem}MB | 拥塞算法: ${cc} | 队列: ${qdisc}"
    echo -e "${Y}提示：网络参数已变更，若出现终端卡顿或断开，请重新连接 SSH 即可。${R}"
}

# ================= 高级动态调优 (防OOM/精准回滚) =================
apply_advanced_optimize() {
    local mode=$1
    warn_container_ro
    local mode_name=$2
    echo -e "${Y}执行${mode_name}...${R}"
    
    # 清理标准模式的配置，防止冲突
    rm -f "$SYSCTL_CONF" "$MODE_FILE" 2>/dev/null

    # 1. 调优前先备份出厂状态（与标准模式共用一份快照）
    take_factory_snapshot

    # 2. 动态推导 TCP 缓冲区上限 (防止小内存机 OOM)
    local mem_total_kb=$(awk '/MemTotal:/{print $2}' /proc/meminfo)
    local mem_mb=$((mem_total_kb / 1024))
    # 核心逻辑: 取内存的 1/32，上限 64MB (67108864)，下限 4MB (4194304)
    local buf_max=$(( mem_mb * 1024 * 1024 / 32 ))
    [ "$buf_max" -gt 67108864 ] && buf_max=67108864
    [ "$buf_max" -lt 4194304 ] && buf_max=4194304

    # UDP 内存阈值同样按物理内存等比推导（单位：页）
    local pages_total=$(( mem_total_kb / 4 ))
    local u_min=$(( pages_total * 379008 / 1048576 ))
    [ "$u_min" -lt 16384 ] && u_min=16384
    [ "$u_min" -gt 1048576 ] && u_min=1048576
    local u_pressure=$(( u_min * 4 / 3 ))
    local u_max=$(( u_min * 2 ))
    
    echo -e "${C}物理内存: ${mem_mb} MB | 推导 TCP 缓冲区上限: $(( buf_max / 1024 / 1024 )) MB${R}"
    
    # 3. 尝试加载 BBR 模块
    modprobe tcp_bbr 2>/dev/null
    local cc="bbr"
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo -e "${RED}警告：内核不支持 BBR，回退到 cubic${R}"
        cc="cubic"
    fi
    # fq 探测与标准模式同步：不支持则回退 fq_codel（通常编译进内核，必然可用）
    local qd="fq"
    local orig_qd_adv=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        echo -e "${RED}警告：内核不支持 fq，回退到 fq_codel${R}"
        qd="fq_codel"
    fi
    # 探测本身是一次内核写入，恢复原值以保无副作用，后续由统一应用流程写入
    [ -n "$orig_qd_adv" ] && sysctl -w net.core.default_qdisc="$orig_qd_adv" >/dev/null 2>&1

    # 4. 生成配置到临时文件 (原子化写入，mktemp 防 symlink 竞态)
    # 注：不设 RETURN trap——下方三条退出路径（探针失败/应用失败/成功mv）已显式清理
    local tmp_conf=$(mktemp /tmp/.yw_adv_sysctl.XXXXXX)
    cat > "$tmp_conf" << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = $qd
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1000000
net.core.somaxconn = 32768

# 动态 TCP 缓冲区调优 (由 MiMi 工具箱计算生成)
net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.ipv4.tcp_rmem = 4096 87380 $buf_max
net.ipv4.tcp_wmem = 4096 65536 $buf_max

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
EOF

    # 根据模式追加参数
    if [ "$mode" == "live" ]; then
        echo -e "${C}已融合直播推流 UDP 大缓冲优化参数${R}"
        cat >> "$tmp_conf" << EOF
# 直播推流 UDP 专属优化 (减少丢包与花屏，阈值按内存推导)
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = $u_min $u_pressure $u_max
net.core.netdev_max_backlog = 32768
EOF
    else
        # 日常代理模式，使用温和的 backlog
        echo "net.core.netdev_max_backlog = 16384" >> "$tmp_conf"
    fi

    # 5. 逐 key 应用并精确计数（与标准模式一致）：
    #    只读容器（/proc/sys 只读）下存在性预检会通过但写入失败，旧的 sysctl -p 整判失败会导致
    #    "持久化一个字都不写但内核已被部分改掉"，与标准模式行为分裂。逐 key 则成功的持久化、失败的诚实报告。
    echo -e "${Y}应用优化参数...${R}"
    local applied=0 failed=0 skipped=0
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        k=$(echo "$k" | xargs); v=$(echo "$v" | xargs)
        [ -z "$k" ] && continue
        if [ ! -f "/proc/sys/${k//.//}" ]; then
            ((skipped++))
            sed -i "/^${k//./\\.}[[:space:]]*=/d" "$tmp_conf"
            continue
        fi
        if LC_ALL=C sysctl -w "$k=$v" >/dev/null 2>&1; then
            ((applied++))
        else
            ((failed++))
            # 写入失败的 key 同样从持久化配置剔除，避免每次开机 sysctl --system 报错刷屏
            sed -i "/^${k//./\\.}[[:space:]]*=/d" "$tmp_conf"
        fi
    done < "$tmp_conf"
    # 校验配置真写进去 + 残行清理兜底：
    #   - mktemp 失败 / 磁盘满 → tmp_conf 空
    #   - 应用循环里 sed 删行不会清空最后一行 → 残留 1-2 行注释/空行
    #   - applied=0（一个都没应用上，如只读容器）
    # 三种情况都不应 mv 一个无效文件覆盖 ADV_SYSCTL_CONF，让用户以为已落盘
    # 用 "至少一行 'key = value'" 作为有效配置的判定
    # 注：grep -c 无匹配时退出码 1 会触发 `|| echo 0`，需用 head -1 取首行避免 "0\n0" 多行字符串
    local _valid_lines
    _valid_lines=$(grep -cE '^[^#[:space:]].*[[:space:]]*=[[:space:]]*' "$tmp_conf" 2>/dev/null | head -1)
    _valid_lines=${_valid_lines:-0}
    if [ "$_valid_lines" -eq 0 ] 2>/dev/null || [ "$applied" -eq 0 ]; then
        echo -e "${RED}❌ 生成 $ADV_SYSCTL_CONF 失败：有效参数行数为 ${_valid_lines:-0}，应用 ${applied} 项${R}" >&2
        echo -e "${RED}   参数未落盘，重启后不会生效（可能是只读容器或所有 key 写入失败）${R}" >&2
        rm -f "$tmp_conf"
        return 1
    fi
    mv -f "$tmp_conf" "$ADV_SYSCTL_CONF"
    chmod 644 "$ADV_SYSCTL_CONF" 2>/dev/null # mktemp 默认 0600，恢复常规配置文件权限
    echo -e "${G}已应用 ${applied} 项参数${R}"
    [ "$skipped" -gt 0 ] && echo -e "${Y}跳过 ${skipped} 项本内核不存在的参数${R}"
    [ "$failed" -gt 0 ] && echo -e "${Y}失败 ${failed} 项只读/不支持的参数（已从持久化配置中剔除）${R}"
    # 本次配置没覆盖的 key 恢复出厂值，避免从其他模式切换后旧值残留
    restore_unmanaged_keys "$ADV_SYSCTL_CONF"
    # 模式标记在应用之后写；applied=0（一个都没应用上，如只读容器）时不写，避免菜单显示与实际不符
    [ "$applied" -gt 0 ] && echo "$mode_name" > "$ADV_MODE_FILE"
    
    local current_mem=$(free -m | awk '/Mem:/{print $2}')
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "内存: ${current_mem}MB | 拥塞算法: ${current_cc} | 队列: ${current_qdisc}"
    echo -e "${Y}提示：网络参数已变更，若出现终端卡顿或断开，请重新连接 SSH 即可。${R}"
    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}${mode_name} 未完全应用（${failed} 项参数失败）${R}"
        return 1
    fi
    echo -e "${G}✅ ${mode_name}完成！配置已持久化到 ${ADV_SYSCTL_CONF}${R}"
}

restore_advanced_default() {
    # 若当前并非高级调优模式：无事可做直接返回。
    # 否则会误删标准模式共用的出厂快照，且只还原内核不清理标准模式配置文件，重启后调优被"复活"。
    if [ ! -f "$ADV_MODE_FILE" ]; then
        echo -e "${Y}当前未启用高级调优，无需还原（如需还原标准模式请使用菜单 3）${R}"
        return 0
    fi
    echo -e "${Y}还原高级调优设置...${R}"
    
    # 1. 移除持久化配置文件
    rm -f "$ADV_SYSCTL_CONF"
    rm -f "$ADV_MODE_FILE"
    
    # 2. 优先从快照恢复 (精准还原)
    if [ -f "$FACTORY_SNAPSHOT" ]; then
        echo -e "${Y}检测到出厂快照，正在精准还原...${R}"
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^# ]] && continue
            [ -z "$key" ] && continue
            key=$(echo "$key" | xargs); val=$(echo "$val" | xargs)
            sysctl -w "$key=$val" >/dev/null 2>&1
        done < "$FACTORY_SNAPSHOT"
        rm -f "$FACTORY_SNAPSHOT"
        echo -e "${G}✅ 已按出厂快照精准还原网络配置${R}"
    else
        # 3. 无快照时的兜底策略
        echo -e "${Y}未找到出厂快照，应用系统默认配置...${R}"
        sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/default_qdisc/d' /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq_codel" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    local current_mem=$(free -m | awk '/Mem:/{print $2}')
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "${G}✅ 还原完毕${R}"
    echo -e "内存: ${current_mem}MB | 拥塞算法: ${current_cc} | 队列: ${current_qdisc}"
    echo -e "${Y}提示：网络参数已变更，若出现终端卡顿或断开，请重新连接 SSH 即可。${R}"
}

bbr_kernel_manage() {
    local vi=$(systemd-detect-virt 2>/dev/null)
    if [[ "$vi" =~ lxc|openvz ]]; then
        echo -e "${RED}当前VPS的架构为 $vi，不支持开启原版BBR加速${R}"
        read -r -s -n 1 -p ""; return
    fi

    echo -e "${Y}点击任意键，即可开启原版BBR加速，ctrl+c退出${R}"
    read -r -s -n 1
    bash <(curl -Ls https://raw.githubusercontent.com/teddysun/across/master/bbr.sh)
}

smart_auto_optimize() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║          🚀 网络与内核优化中心             ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        
        local current_kernel=$(uname -r)
        local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local current_mode="默认设置"
        if [ -f "$MODE_FILE" ]; then
            current_mode=$(cat "$MODE_FILE")
        elif [ -f "$ADV_MODE_FILE" ]; then
            current_mode=$(cat "$ADV_MODE_FILE")
        elif [ "$current_cc" = "bbr" ]; then
            current_mode="原版 BBR"
        elif [ "$current_cc" = "cubic" ]; then
            current_mode="默认设置"
        fi
        
        echo -e "当前内核: ${C}$current_kernel${R}"
        echo -e "当前模式: ${Y}$current_mode${R}\n"
        echo -e "Linux系统内核参数优化"
        echo -e "--------------------"
        echo -e "${Y}1 均衡优化模式：       ${R}在性能与资源消耗之间取得平衡，适合日常使用。"
        echo -e "${Y}2 直播优化模式：       ${R}针对直播推流优化，UDP 缓冲区加大，减少延迟。"
        echo -e "${Y}3 还原默认设置：       ${R}将系统设置还原为默认配置。"
        echo -e "${C}4 XanMod BBRv3 内核管理${R}"
        echo -e "${C}5 开启原版 BBR 加速 (teddysun)${R}"
        echo -e "${G}6 高级代理调优：       ${R}动态推导TCP防OOM，带快照精准回滚，适合日常。"
        echo -e "${G}7 高级直播调优：       ${R}动态TCP+加大UDP缓冲防OOM防花屏，适合TikTok。"
        echo -e "${G}8 还原高级调优：       ${R}从快照精准还原出厂网络参数。"
        echo -e "--------------------"
        echo -e "${H}0. 返回上一级选单${R}"
        echo -e "--------------------"
        read -r -e -p "请输入你的选择: " c
        
        case "$c" in
            1) clear; if apply_optimize balance "均衡优化模式"; then echo -e "${G}操作完成${R}"; else echo -e "${RED}操作未完成${R}"; fi; read -r -s -n 1 -p "按任意键继续..." ;;
            2) clear; if apply_optimize live "直播优化模式"; then echo -e "${G}操作完成${R}"; else echo -e "${RED}操作未完成${R}"; fi; read -r -s -n 1 -p "按任意键继续..." ;;
            3) clear; if restore_default; then echo -e "${G}操作完成${R}"; else echo -e "${RED}操作未完成${R}"; fi; read -r -s -n 1 -p "按任意键继续..." ;;
            4) clear; xanmod_manage ;;
            5) clear; bbr_kernel_manage ;;
            6) clear; if apply_advanced_optimize proxy "高级代理调优"; then echo -e "${G}操作完成${R}"; else echo -e "${RED}操作未完成${R}"; fi; read -r -s -n 1 -p "按任意键继续..." ;;
            7) clear; if apply_advanced_optimize live "高级直播调优"; then echo -e "${G}操作完成${R}"; else echo -e "${RED}操作未完成${R}"; fi; read -r -s -n 1 -p "按任意键继续..." ;;
            8) clear; if restore_advanced_default; then echo -e "${G}操作完成${R}"; else echo -e "${RED}操作未完成${R}"; fi; read -r -s -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
        esac
    done
}

# ================= 融合科技佬的 XanMod 核心逻辑 =================
xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/xanmod-release.list"
    local key_url="https://dl.xanmod.org/archive.key"
    local os_codename=""

    if command -v lsb_release >/dev/null 2>&1; then
        os_codename=$(lsb_release -sc)
    elif [ -r /etc/os-release ]; then
        os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi

    # 空代号先判：grep -qw "" 空模式恒匹配，会把空代号吞进 "releases" 分支
    if [ -z "$os_codename" ]; then
        echo -e "${RED}无法获取系统代号，无法配置XanMod源${R}"
        return 1
    fi
    local orig_codename="$os_codename"

    if ! echo "bookworm trixie forky sid noble plucky questing resolute faye gigi wilma xia zara zena" | grep -qw "$os_codename"; then
        os_codename="releases"
    fi

    if echo "jammy focal bullseye buster" | grep -qw "$orig_codename" || [ "$os_codename" = "releases" ]; then
        echo -e "${RED}XanMod 官方已停止对当前系统($orig_codename)的 APT 源支持，请升级至 Debian12 / Ubuntu24 或更高版本。${R}"
        return 1
    fi

    echo -e "${Y}正在安装依赖并下载密钥...${R}"
    apt-get install -y wget gnupg ca-certificates >/dev/null 2>&1
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    if ! wget -qO - "$key_url" | gpg --dearmor -o "$keyring" --yes; then
        echo -e "${RED}官方密钥下载失败${R}"
        return 1
    fi
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
    echo -e "${G}XanMod 源配置完成 (系统代号: $os_codename)${R}"
}

xanmod_detect_psabi_level() {
    local psabi_output=""
    psabi_output=$(awk 'BEGIN {
        while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
        if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
        if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
        if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
        if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
        if (level > 0) { print level; exit }
        exit 1
    }' /proc/cpuinfo 2>/dev/null) || return 1
    printf '%s' "$psabi_output" | tr -dc '0-9' | head -c 1
}

xanmod_package_available() {
    local package="$1"
    # Candidate: (none) 表示包存在但无候选版本，必须排除；版本号恒以数字开头
    # LC_ALL=C：apt 输出走 gettext，中文 locale 下是"候选："而非"Candidate:"，必须固定英文再 grep
    LC_ALL=C apt-cache policy "$package" 2>/dev/null | grep -q 'Candidate: [0-9]'
}

xanmod_detect_package() {
    local psabi_level=""
    local level=""
    local package=""
    local prefix_list="linux-xanmod linux-xanmod-lts"

    psabi_level=$(xanmod_detect_psabi_level) || return 1
    [ -n "$psabi_level" ] || return 1
    [ "$psabi_level" -gt 3 ] && psabi_level=3

    apt-get update -y >/dev/null 2>&1

    for prefix in $prefix_list; do
        level="$psabi_level"
        while [ "$level" -ge 1 ]; do
            package="${prefix}-x64v${level}"
            if xanmod_package_available "$package"; then
                echo -e "${G}已自动匹配合适安装包: $package${R}" >&2
                printf '%s\n' "$package"
                return 0
            fi
            level=$((level - 1))
        done
    done

    echo -e "${RED}软件源中未找到适配此CPU的XanMod内核包${R}" >&2
    return 1
}

xanmod_installed() {
    dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'
}

xanmod_install_or_update() {
    local action="$1"
    local package=""

    xanmod_add_repo || {
        echo -e "${RED}XanMod官方仓库配置失败，请稍后重试${R}"
        return 1
    }

    package=$(xanmod_detect_package) || {
        echo -e "${RED}无法识别当前CPU或找不到匹配内核包，已取消安装${R}"
        return 1
    }

    echo -e "${Y}正在更新软件源并安装内核 (包大小约100MB，请耐心等待)...${R}"
    apt-get update -y
    if [ "$action" = "update" ]; then
        apt-get install -y --only-upgrade "$package" || apt-get install -y "$package" || {
            echo -e "${RED}XanMod内核更新失败，请检查软件源或稍后重试${R}"
            return 1
        }
    else
        apt-get install -y "$package" || {
            echo -e "${RED}XanMod内核安装失败，请检查软件源或稍后重试${R}"
            return 1
        }
    fi

    # 安装新内核后：保留用户已有调优模式（仅在无任何调优配置时才应用均衡模式），不再静默删除高级调优
    if [ -f "$ADV_MODE_FILE" ] || [ -f "$MODE_FILE" ]; then
        echo -e "${Y}已保留现有网络调优配置（更换内核后如需重新调优，可再次运行对应模式）${R}"
    else
        apply_optimize balance "均衡优化模式"
    fi
    
    echo -e "${G}XanMod BBRv3内核处理完成。重启后生效${R}"
    ask_reboot
}

xanmod_uninstall() {
    echo -e "${Y}正在卸载 XanMod 内核...${R}"
    apt-get purge -y 'linux-*xanmod*'
    apt-get autoremove -y
    if command -v update-grub >/dev/null 2>&1; then
        # 改 grub 前先备份：用户可能设置过 GRUB_DEFAULT=saved 或指定内核序号，静默丢失后无法还原
        local _grub_backup_ok=0
        if [ -f /etc/default/grub ]; then
            local _grub_bak="/etc/default/grub.bak.$(date +%s)"
            if cp -a /etc/default/grub "$_grub_bak" 2>/dev/null; then
                echo -e "${Y}已备份 GRUB 配置到 $_grub_bak${R}"
                echo -e "${Y}如需还原：cp -a $_grub_bak /etc/default/grub && update-grub${R}"
                _grub_backup_ok=1
            else
                echo -e "${RED}❌ GRUB 配置备份失败（可能磁盘满或权限不足），未改动 GRUB_DEFAULT${R}" >&2
                echo -e "${RED}   原配置保留，请手动备份后重试卸载${R}" >&2
            fi
        else
            echo -e "${Y}/etc/default/grub 不存在，跳过 GRUB_DEFAULT 修改${R}"
        fi
        # 只在备份成功时才改 GRUB_DEFAULT，否则保留原值（仅 update-grub 让卸载后内核列表生效）
        [ "$_grub_backup_ok" -eq 1 ] && sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/g' /etc/default/grub
        # 检查 update-grub 退出码：失败时 grub.cfg 未重新生成，
        # GRUB_DEFAULT 已改成 0 但启动项列表没刷新 → 旧配置若指向已删除内核条目会启动失败/进错系统
        # 不能静默放过，必须显式警告让用户手动处理
        if ! update-grub; then
            echo -e "${RED}❌ update-grub 失败：GRUB_DEFAULT 已改为 0，但 grub.cfg 未重新生成${R}" >&2
            echo -e "${RED}   请手动执行：update-grub 或 grub2-mkconfig -o /boot/grub2/grub.cfg${R}" >&2
            echo -e "${RED}   如需还原原 GRUB_DEFAULT：cp -a <备份文件> /etc/default/grub && update-grub${R}" >&2
        fi
    else
        # grub2-mkconfig 同样检查退出码
        if ! grub2-mkconfig -o /boot/grub2/grub.cfg; then
            echo -e "${RED}❌ grub2-mkconfig 失败：grub.cfg 未重新生成，请手动执行${R}" >&2
        fi
    fi
    rm -f /etc/apt/sources.list.d/xanmod-release.list
    rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
    echo -e "${G}XanMod内核已卸载。重启后生效${R}"
    ask_reboot
}

xanmod_manage() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}仅支持 Debian/Ubuntu 系统安装 XanMod 内核${R}"
        read -r -s -n 1 -p ""; return
    fi

    if xanmod_installed; then
        while true; do
            clear
            local kernel_version=$(uname -r)
            echo -e "${G}您已安装xanmod的BBRv3内核${R}"
            echo -e "当前内核版本: ${C}$kernel_version${R}\n"
            echo -e "${Y}内核管理${R}"
            echo -e "------------------------"
            echo -e "${Y}1. 更新BBRv3内核              2. 卸载BBRv3内核${R}"
            echo -e "------------------------"
            echo -e "${H}0. 返回上一级选单${R}"
            read -r -e -p "请输入你的选择: " sub_choice
            case $sub_choice in
                1) xanmod_install_or_update update ;;
                2) xanmod_uninstall ;;
                *) break ;;
            esac
        done
    else
        clear
        echo -e "${Y}设置BBR3加速${R}"
        echo -e "------------------------------------------------"
        echo -e "仅支持Debian/Ubuntu"
        echo -e "请备份数据，将为你升级Linux内核开启BBR3"
        echo -e "------------------------------------------------"
        local choice=""
        # EOF（如管道答案耗尽）不应默认放行安装内核——这是高风险操作
        if ! read -r -e -p "确定继续吗？[Y/n]: " choice; then
            echo "" >&2
            echo -e "${RED}错误：输入 EOF，已取消（内核安装不会默认放行）${R}" >&2
            return 1
        fi
        case "$choice" in
            [Yy]|"") xanmod_install_or_update install ;;
            *) echo -e "${Y}已取消${R}" ;;
        esac
    fi
}

# ================= Sing-Box 核心 =================
sb_init_conf() {
    mkdir -p /etc/sing-box
    cat > "$SB_CONF" <<'EOF'
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "selector", "tag": "proxy", "outbounds": ["direct"], "default": "direct"},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF
}

# 原子写配置：从临时文件 mv 到目标，但保留软链语义 + 原文件权限
# 用法：sb_write_conf_atomic <tmp_file> <target_file>
# 返回 0 成功，1 失败（已打印错误消息）
# 解决三个问题：
#   1. 配置文件是软链时（如挂到 dotfiles 目录管理），mv 会把软链替换成普通文件，
#      软链指向的目标文件永远停在旧内容。检测软链并改用 cp 写入目标。
#   2. mv 失败时（权限/磁盘满）原配置不应被破坏
#   3. 不写死 chmod 644：原文件若是 600（用户主动收紧权限，config.json 含 Reality 私钥/hy2 密码），
#      写死 chmod 644 会放宽权限。改成保留原权限：先记下原 stat，写完恢复。
sb_write_conf_atomic() {
    local src="$1" dst="$2"
    # 检查 jq 是否真生成了有效内容（jq 失败时 tmp 文件可能为空或半截）
    if [ ! -s "$src" ]; then
        echo -e "${RED}❌ 配置生成失败：临时文件为空（jq 可能异常退出）${R}" >&2
        return 1
    fi
    # 记录原文件权限（软链则记真实目标的权限），写完恢复，避免写死 644 放宽用户收紧的权限
    # config.json 含 Reality 私钥、hy2 密码等敏感信息，600 应保留为 600
    local _orig_mode=""
    if [ -L "$dst" ]; then
        local _rt
        _rt=$(readlink -f "$dst" 2>/dev/null)
        [ -n "$_rt" ] && [ -e "$_rt" ] && _orig_mode=$(stat -c '%a' "$_rt" 2>/dev/null)
    elif [ -e "$dst" ]; then
        _orig_mode=$(stat -c '%a' "$dst" 2>/dev/null)
    fi

    if [ -L "$dst" ]; then
        # 目标是软链：mv 会替换软链本身而非写入指向的文件，需用 cp 写入软链目标
        # 用 `--remove-destination` 让 cp 先 unlink 目标文件再写新内容（避免 symlink 写穿邻居）
        # 但更安全的方式：解析软链指向的真实路径，直接写那个路径
        local real_target
        real_target=$(readlink -f "$dst" 2>/dev/null)
        if [ -z "$real_target" ]; then
            echo -e "${RED}❌ 配置文件 $dst 是软链但无法解析目标${R}" >&2
            return 1
        fi
        if ! cp --remove-destination "$src" "$real_target" 2>/dev/null; then
            echo -e "${RED}❌ 写入软链目标 $real_target 失败${R}" >&2
            return 1
        fi
        # 恢复原权限（不主动 chmod 644）
        [ -n "$_orig_mode" ] && chmod "$_orig_mode" "$real_target" 2>/dev/null
    else
        # 普通文件：mv 原子替换（同文件系统下走 rename(2)，不破坏 symlink）
        # mv 后新文件继承 src 的权限（mktemp 默认 600），所以仍需恢复原权限
        if ! mv -f "$src" "$dst" 2>/dev/null; then
            echo -e "${RED}❌ mv 替换 $dst 失败（可能磁盘满或权限不足）${R}" >&2
            return 1
        fi
        [ -n "$_orig_mode" ] && chmod "$_orig_mode" "$dst" 2>/dev/null
    fi
    return 0
}

sb_check() {
    if ! command -v $SB_BIN >/dev/null 2>&1; then
        echo -e "${RED}请先安装 Sing-Box${R}"; read -r -s -n 1 -p ""; return 1;
    fi

    # 先做只读语法校验：只有语法真正损坏才备份重置，绝不因服务没起来就清空用户节点
    if ! $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        echo -e "${Y}检测到配置文件语法错误，正在备份并重置为基础配置...${R}"
        # 备份用 cp 而非 mv：保留原文件（含软链本身）在原位置不动
        #   - 若用 mv，软链本身会被移走，备份里是个软链（指向已不存在的路径），
        #     软链指向的目标文件永远停在坏内容
        #   - 用 cp -a 复制内容（解析软链），.bak 里存的是真实配置内容
        #   - 备份后原文件（软链本身或普通文件）仍在原位置，再让 sb_init_conf 走 helper 写入
        local _bak_file="${SB_CONF}.bak.$(date +%s)"
        if ! cp -a "$SB_CONF" "$_bak_file" 2>/dev/null; then
            echo -e "${RED}❌ 备份失败：无法复制 $SB_CONF 到 $_bak_file（可能磁盘满或权限不足）${R}" >&2
            echo -e "${RED}   原配置未改动，请手动备份后重试：cp -a $SB_CONF ${SB_CONF}.manual_bak${R}" >&2
            read -r -s -n 1 -p ""
            return 1
        fi
        # 验证备份是真内容而非空文件或软链本身
        # cp -a 对软链默认复制软链本身；要复制指向的内容需 -L（dereference）
        # 重新检查：如果 _bak_file 是软链或空，改用 cp -aL 重做（解析软链）
        if [ -L "$_bak_file" ] || [ ! -s "$_bak_file" ]; then
            rm -f "$_bak_file" 2>/dev/null
            if ! cp -aL "$SB_CONF" "$_bak_file" 2>/dev/null; then
                echo -e "${RED}❌ 备份失败：无法复制 $SB_CONF 内容（软链解析失败或磁盘满）${R}" >&2
                echo -e "${RED}   原配置未改动，请手动备份后重试${R}" >&2
                read -r -s -n 1 -p ""
                return 1
            fi
        fi
        touch "$_bak_file" 2>/dev/null   # 更新 mtime，避免被轮换删除
        # 损坏重置的备份只保留最近 5 份（按文件名时间戳排序，不依赖 mtime）
        ls -1 "${SB_CONF}.bak."* 2>/dev/null | sort -t. -k3 -n | head -n -5 | xargs -r rm -f
        # 重置：用临时文件 + sb_write_conf_atomic 写入，处理软链 + 保留权限
        # sb_init_conf 直接 cat > $SB_CONF 会破坏软链（替换成普通文件）
        local _init_tmp
        _init_tmp=$(mktemp /tmp/.yw_sb_init.XXXXXX) || {
            echo -e "${RED}❌ 无法创建临时文件，重置失败${R}" >&2
            return 1
        }
        # 生成基础配置到临时文件
        cat > "$_init_tmp" <<'EOF'
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "selector", "tag": "proxy", "outbounds": ["direct"], "default": "direct"},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF
        if ! sb_write_conf_atomic "$_init_tmp" "$SB_CONF"; then
            rm -f "$_init_tmp"
            return 1
        fi
        rm -f "$_init_tmp"
        # 重置后重启服务：避免内存中仍跑着旧配置、与磁盘不一致
        systemctl restart sing-box >/dev/null 2>&1
        sleep 2
    fi

    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl restart sing-box >/dev/null 2>&1
        sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ Sing-Box 服务无法启动（配置语法正常），请检查端口占用或执行 journalctl -u sing-box 排查${R}"
            read -r -s -n 1 -p ""
            return 1
        fi
    fi
    return 0
}

sb_install() {
    local fresh=1
    local old_binary_backup=""
    if command -v $SB_BIN >/dev/null 2>&1; then
        fresh=0
        local cur_ver=$($SB_BIN version 2>/dev/null | head -1)
        echo -e "${Y}Sing-Box 已安装 (${cur_ver})${R}"
        local up
        read -r -e -p "是否重新安装/升级到最新版？[y/N]: " up
        [[ "$up" =~ ^[Yy]$ ]] || { read -r -s -n 1 -p ""; return; }
    fi
    local arch=$(uname -m); case "$arch" in x86_64) arch="amd64";; aarch64) arch="arm64";; *) echo -e "${RED}❌ 不支持 ${arch}${R}"; return 1;; esac

    # jq 用 // empty：API 限流返回错误 JSON 时 .tag_name 是字面量 "null"，必须过滤掉否则拼出 sing-box-null-*.tar.gz
    local latest_ver=$(curl -sL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name // empty' | sed 's/v//')
    if [ -z "$latest_ver" ] || [ "$latest_ver" = "null" ]; then
        latest_ver="1.11.4"
        echo -e "${Y}无法获取最新版本（GitHub API 不可达/限流），将安装 v${latest_ver}${R}"
    fi
    echo -e "${Y}正在安装 Sing-Box v${latest_ver}...${R}"
    mkdir -p /etc/sing-box
    local workdir=$(mktemp -d /tmp/.yw_sbdl.XXXXXX)
    # 挂多信号 trap 清理 workdir：curl 下载 / tar 解压期间 Ctrl+C 或被 TERM 时，
    # 正常退出路径都覆盖不到，会留下 /tmp/.yw_sbdl.* 垃圾目录
    # 用局部辅助函数统一清理 + 解除 trap，避免每个 return 1 路径重复
    _sb_install_trap_cleanup() {
        rm -rf "$workdir" 2>/dev/null
        trap - EXIT INT TERM HUP
        # 恢复脚本开头的全局 trap（`trap 'rm -f "$CHECK_LOG"' EXIT`）
        trap 'rm -f "$CHECK_LOG"' EXIT
    }
    trap 'rc=$?; rm -rf "'"$workdir"'" 2>/dev/null; exit $rc' EXIT INT TERM HUP
    curl -L -o "${workdir}/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz" 2>/dev/null
    tar xzf "${workdir}/sb.tar.gz" -C "$workdir" 2>/dev/null || { echo -e "${RED}❌ 解压失败${R}"; _sb_install_trap_cleanup; return 1; }
    [ -f "${workdir}/sing-box-${latest_ver}-linux-${arch}/sing-box" ] || { echo -e "${RED}❌ 二进制文件缺失${R}"; _sb_install_trap_cleanup; return 1; }

    # 升级前备份旧二进制（同目录，便于失败回滚）
    # 注：fresh=1 路径下若二进制不存在（rm 过/容器重置），跳过备份；
    # 但若二进制不存在而配置存在，视为"重装但配置保留"——必须保护配置（见下面 fresh 分支）
    if [ "$fresh" -eq 0 ] && [ -f "$SB_BIN" ]; then
        old_binary_backup="${SB_BIN}.old.$(date +%s)"
        # 检查 cp 退出码：失败（磁盘满/权限）时显式警告，不静默继续
        # 否则真需要回滚时才发现备份不存在（回滚分支有存在性守卫不会乱覆盖，但用户以为有备份其实没有）
        if ! cp -a "$SB_BIN" "$old_binary_backup" 2>/dev/null; then
            echo -e "${RED}❌ 旧二进制备份失败（可能磁盘满或权限不足），无法回滚，已取消升级${R}" >&2
            _sb_install_trap_cleanup
            return 1
        fi
    fi

    # 用临时文件 + mv 原子替换二进制，避免中途被杀留下半截文件
    local _new_bin="${workdir}/sing-box-${latest_ver}-linux-${arch}/sing-box"
    chmod +x "$_new_bin" 2>/dev/null
    if ! mv -f "$_new_bin" "$SB_BIN" 2>/dev/null; then
        echo -e "${RED}❌ 写入 $SB_BIN 失败${R}"
        # 回滚旧二进制
        [ -n "$old_binary_backup" ] && [ -f "$old_binary_backup" ] && mv -f "$old_binary_backup" "$SB_BIN" 2>/dev/null
        _sb_install_trap_cleanup
        return 1
    fi
    # 二进制已 mv 到 SB_BIN，workdir 此时可清，解除 trap 避免影响后续 systemctl 调用
    _sb_install_trap_cleanup

    if [ "$fresh" -eq 1 ]; then
        # fresh 路径：但若配置已存在（二进制被 rm 但配置保留），必须备份后再重置，否则用户节点全丢
        if [ -f "$SB_CONF" ]; then
            local _conf_bak="${SB_CONF}.bak.$(date +%s)"
            cp -a "$SB_CONF" "$_conf_bak" 2>/dev/null
            touch "$_conf_bak" 2>/dev/null
            echo -e "${Y}检测到现有配置，已备份到 ${_conf_bak}${R}"
            echo -e "${Y}如需恢复节点：cp ${_conf_bak} ${SB_CONF} && systemctl restart sing-box${R}"
        fi
        sb_init_conf
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box Service
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box --now >/dev/null 2>&1
        # fresh 后验证服务状态：装完不验证就报成功是误导
        sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 安装完成但服务未启动，请检查 journalctl -u sing-box${R}"
            return 1
        fi
        # 清理旧二进制备份（fresh 后没用了）
        [ -n "$old_binary_backup" ] && rm -f "$old_binary_backup" 2>/dev/null
    else
        # 升级：保留现有配置，重启服务并校验结果
        # 先校验新二进制是否能解析现有配置，避免重启后服务挂
        if ! "$SB_BIN" check -c "$SB_CONF" >/dev/null 2>&1; then
            echo -e "${RED}❌ 新二进制无法解析现有配置（可能版本不兼容），正在回滚旧二进制...${R}"
            if [ -n "$old_binary_backup" ] && [ -f "$old_binary_backup" ]; then
                mv -f "$old_binary_backup" "$SB_BIN" 2>/dev/null
                chmod +x "$SB_BIN" 2>/dev/null
                echo -e "${G}已回滚到旧版本${R}"
            else
                echo -e "${RED}无旧二进制备份可回滚，请手动处理${R}"
            fi
            return 1
        fi
        systemctl restart sing-box >/dev/null 2>&1
        sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 升级后服务未启动，正在回滚旧二进制...${R}"
            journalctl -u sing-box -n 5 --no-pager 2>&1 | sed 's/^/  /'
            if [ -n "$old_binary_backup" ] && [ -f "$old_binary_backup" ]; then
                mv -f "$old_binary_backup" "$SB_BIN" 2>/dev/null
                chmod +x "$SB_BIN" 2>/dev/null
                systemctl restart sing-box >/dev/null 2>&1
                sleep 2
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    echo -e "${G}已回滚到旧版本，服务恢复正常${R}"
                else
                    echo -e "${RED}回滚后服务仍未恢复，请手动检查（systemctl status sing-box）${R}"
                fi
            else
                echo -e "${RED}无旧二进制备份可回滚，请手动重装旧版本${R}"
            fi
            return 1
        fi
        # 升级成功，清理旧二进制备份
        [ -n "$old_binary_backup" ] && rm -f "$old_binary_backup" 2>/dev/null
    fi
    echo -e "${G}✅ 安装成功！${R}"
    read -r -s -n 1 -p ""
}

save_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    elif [ -f /usr/lib/systemd/system/iptables.service ] || [ -x /etc/init.d/iptables ]; then
        # RHEL/CentOS 系：经由 iptables-services 持久化，开机自动加载
        service iptables save >/dev/null 2>&1
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    fi
}

open_port() {
    local port=$1
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${RED}警告：未检测到 iptables，端口 ${port} 可能未实际放行（firewalld/ufw/nft 环境请手动放行）${R}" >&2
        return 1
    fi
    iptables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
    iptables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${port} -j ACCEPT
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport ${port} -j ACCEPT
        ip6tables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport ${port} -j ACCEPT
    fi
    fw_sync_open "$port"
    save_iptables
}
# firewalld / ufw 运行时同步放行：手工 iptables 规则会在 firewalld reload 后丢失，ufw 同理
fw_sync_open() {
    local port=$1
    if systemctl is-active --quiet firewalld 2>/dev/null && command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --add-port=${port}/tcp >/dev/null 2>&1
        firewall-cmd --add-port=${port}/udp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${port}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${port}/udp >/dev/null 2>&1
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow ${port}/tcp >/dev/null 2>&1
        ufw allow ${port}/udp >/dev/null 2>&1
    fi
}
fw_sync_close() {
    local port=$1
    if systemctl is-active --quiet firewalld 2>/dev/null && command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --remove-port=${port}/tcp >/dev/null 2>&1
        firewall-cmd --remove-port=${port}/udp >/dev/null 2>&1
        firewall-cmd --permanent --remove-port=${port}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --remove-port=${port}/udp >/dev/null 2>&1
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow ${port}/tcp >/dev/null 2>&1
        ufw delete allow ${port}/udp >/dev/null 2>&1
    fi
}
close_port() {
    local port=$1
    [ -z "$port" ] && return 0
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${Y}未检测到 iptables，跳过端口 $port 的防火墙关闭${R}"
        return 1
    fi
    iptables -D INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null
        ip6tables -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null
    fi
    fw_sync_close "$port"
    save_iptables
}

input_custom_port() {
    local port
    while true; do
        # read 失败（EOF）时退出而非走默认（管道答案耗尽时不应继续随机建节点）
        if ! read -r -e -p "请输入端口 (1-65535，回车随机生成): " port; then
            echo "" >&2
            echo -e "${RED}错误：输入 EOF，已取消${R}" >&2
            return 1
        fi
        if [ -z "$port" ]; then
            # 随机端口同样检测占用，避免撞端口后白走一轮写配置→重启失败→回滚
            while true; do
                port=$(shuf -i 443-65535 -n 1)
                ss -tuln | grep -q ":$port " || break
            done
            echo -e "${Y}已随机生成端口: $port${R}" >&2
            break
        fi
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}端口必须在 1-65535 之间，请重新输入${R}" >&2
            continue
        fi
        # 先归一化前导零再做范围/占用检查：顺序不能反，
        # 否则输入 08443 时 grep ":08443 " 匹配不到已监听的 :8443，占用检查被绕过
        port=$((10#$port))
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}端口必须在 1-65535 之间，请重新输入${R}" >&2
        elif ss -tuln | grep -q ":$port "; then
            echo -e "${RED}端口 $port 已被占用，请重新输入${R}" >&2
        else
            break
        fi
    done
    echo "$port"
}

input_custom_tag() {
    local default_tag=$1
    local custom_tag
    while true; do
        # read 失败（EOF）时退出而非走默认名
        if ! read -r -e -p "请输入节点名称 (回车使用默认: $default_tag): " custom_tag; then
            echo "" >&2
            echo -e "${RED}错误：输入 EOF，已取消${R}" >&2
            return 1
        fi
        if [ -z "$custom_tag" ]; then
            custom_tag="$default_tag"
        else
            # 过滤路径分隔符，防止 meta 文件路径穿越
            custom_tag="${custom_tag//\//_}"
        fi
        # 重名校验：inbound/outbound tag 必须唯一，否则 meta 文件互相覆盖、删除时误删同名节点
        if [ -f "$SB_CONF" ] && jq -e --arg t "$custom_tag" \
            '((.inbounds // []) + (.outbounds // []) | map(select(.tag==$t)) | length) > 0' \
            "$SB_CONF" >/dev/null 2>&1; then
            echo -e "${RED}名称 \"$custom_tag\" 已存在，请换一个${R}" >&2
            continue
        fi
        echo "$custom_tag"
        return
    done
}

sb_add_reality() {
    sb_check || return
    local server_ip=$(get_my_ip)
    if [ -z "$server_ip" ]; then
        echo -e "${RED}❌ 无法获取服务器 IP（网络不可达），请检查网络后重试${R}"
        read -r -s -n 1 -p ""
        return 1
    fi
    local listen_addr=$(sb_listen_addr)
    echo -e "${Y}设置 VLESS-Reality 端口${R}"
    local port
    port=$(input_custom_port) || return 1   # EOF 时 input 返回 1
    local uuid=$($SB_BIN generate uuid)
    local sni="apple.com"
    local keys_output=$($SB_BIN generate reality-keypair)
    local priv_key=$(echo "$keys_output" | awk '/PrivateKey/{print $2}')
    local pub_key=$(echo "$keys_output" | awk '/PublicKey/{print $2}')
    local short_id=$($SB_BIN generate rand --hex 4)

    local default_tag="vless-reality-${port}"
    local node_tag
    node_tag=$(input_custom_tag "$default_tag") || return 1   # EOF 时 input 返回 1

    local enable_vision=""
    if ! read -r -e -p "是否开启 xtls-rprx-vision 流控？[Y/n]: " enable_vision; then
        echo "" >&2; echo -e "${RED}错误：输入 EOF，已取消${R}" >&2; return 1
    fi
    local flow=""
    if [[ "$enable_vision" =~ ^[Yy]$|^$ ]]; then
        flow="xtls-rprx-vision"
    fi

    # flock 检测：锁文件无法打开时显式警告，不能静默失效让并发保护名存实亡
    # 用 `exec 200>"$lock"` 先试打开，失败则不进锁块
    if ! (exec 200>"$SB_CONF_LOCK") 2>/dev/null; then
        echo -e "${RED}❌ 无法创建锁文件 $SB_CONF_LOCK，可能权限不足，已取消${R}"
        return 1
    fi
    (
        flock -x 200 || { echo -e "${RED}❌ flock 获取锁失败，并发保护失效，已取消${R}" >&2; exit 1; }
        cp "$SB_CONF" "${SB_CONF}.bak"
        # 锁内复查：input_custom_tag 的重名检查在锁外，并发添加同名节点有竞态窗口
        if jq -e --arg t "$node_tag" '((.inbounds // []) + (.outbounds // []) | map(select(.tag==$t)) | length) > 0' "$SB_CONF" >/dev/null 2>&1; then
            echo -e "${RED}节点名 $node_tag 已存在（并发冲突），本次添加已取消${R}"
            exit 1  # 子 shell 内 exit，仅终止本锁块
        fi


        local node_json=$(jq -n \
          --arg tag "$node_tag" \
          --argjson port $port \
          --arg uuid "$uuid" \
          --arg sni "$sni" \
          --arg priv_key "$priv_key" \
          --arg short_id "$short_id" \
          --arg flow "$flow" \
          --arg listen "$listen_addr" \
          '{
            tag: $tag,
            type: "vless",
            listen: $listen,
            listen_port: $port,
            users: (if $flow == "" then [{uuid: $uuid}] else [{uuid: $uuid, flow: $flow}] end),
            tls: {
              enabled: true,
              server_name: $sni,
              reality: {
                enabled: true,
                handshake: {server: $sni, server_port: 443},
                private_key: $priv_key,
                short_id: [$short_id]
              }
            }
          }')

        # 用 jq 生成新配置到临时文件；检查 jq 退出码作为纵深防御
        # jq 失败（产出空/半截 JSON）时不应继续覆盖原配置
        if ! jq --argjson node "$node_json" '.inbounds += [$node]' "$SB_CONF" > "$SB_CONF.tmp" 2>/dev/null; then
            echo -e "${RED}❌ jq 生成新配置失败，原配置未改动${R}" >&2
            cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
            rm -f "$SB_CONF.tmp"
            exit 1
        fi

        if $SB_BIN check -c "$SB_CONF.tmp" > "$CHECK_LOG" 2>&1; then
            # 用 helper 写配置：处理软链 + mv 失败
            if ! sb_write_conf_atomic "$SB_CONF.tmp" "$SB_CONF"; then
                cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
                exit 1
            fi
            open_port $port

            cat > "${META_DIR}/${node_tag}.json" <<EOF
{"public_key":"$pub_key","short_id":"$short_id","sni":"$sni","uuid":"$uuid","port":$port,"flow":"$flow"}
EOF

            # 节点链接在 systemctl restart 之前打印：
            # 配置已生效（写入磁盘 + open_port 已放行），即使 restart 后续失败或用户 Ctrl+C 中断等待，
            # 节点实际已可访问——只是服务进程尚未重新加载。打印成功+链接让用户知道已建成。
            echo -e "${G}✅ VLESS-Reality 部署成功！${R}"
            local flow_param=""
            if [ -n "$flow" ]; then
                flow_param="&flow=${flow}"
            fi
            local link="vless://${uuid}@${server_ip}:${port}?encryption=none${flow_param}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#$(urlencode "$node_tag")"
            echo -e "${C}节点链接: ${link}${R}"

            systemctl restart sing-box
            sleep 2
            if ! systemctl is-active --quiet sing-box; then
                # 重启失败：节点配置已生效但服务未起来——回滚配置让服务能跑
                echo -e "${RED}❌ Sing-Box 启动失败！可能是端口冲突，正在回滚配置...${R}" >&2
                journalctl -u sing-box -n 10 --no-pager >&2
                cp "${SB_CONF}.bak" "$SB_CONF"
                close_port $port
                rm -f "${META_DIR}/${node_tag}.json"
                systemctl restart sing-box
                echo -e "${RED}❌ 节点已回滚，链接暂不可用${R}" >&2
            fi
        else
            echo -e "${RED}❌ 校验失败，错误详情：${R}"
            cat "$CHECK_LOG"
            cp "${SB_CONF}.bak" "$SB_CONF"
            rm -f "$SB_CONF.tmp"
        fi
    ) 200>"$SB_CONF_LOCK"
    read -r -s -n 1 -p ""
}

sb_add_vless_tcp() {
    sb_check || return
    local server_ip=$(get_my_ip)
    if [ -z "$server_ip" ]; then
        echo -e "${RED}❌ 无法获取服务器 IP（网络不可达），请检查网络后重试${R}"
        read -r -s -n 1 -p ""
        return 1
    fi
    local listen_addr=$(sb_listen_addr)
    echo -e "${Y}设置 VLESS-TCP 端口${R}"
    local port
    port=$(input_custom_port) || return 1
    local uuid=$($SB_BIN generate uuid)

    local default_tag="vless-tcp-${port}"
    local node_tag
    node_tag=$(input_custom_tag "$default_tag") || return 1

    # flock 检测
    if ! (exec 200>"$SB_CONF_LOCK") 2>/dev/null; then
        echo -e "${RED}❌ 无法创建锁文件 $SB_CONF_LOCK，已取消${R}"
        return 1
    fi
    (
        flock -x 200 || { echo -e "${RED}❌ flock 获取锁失败，并发保护失效，已取消${R}" >&2; exit 1; }
        cp "$SB_CONF" "${SB_CONF}.bak"
        # 锁内复查：input_custom_tag 的重名检查在锁外，并发添加同名节点有竞态窗口
        if jq -e --arg t "$node_tag" '((.inbounds // []) + (.outbounds // []) | map(select(.tag==$t)) | length) > 0' "$SB_CONF" >/dev/null 2>&1; then
            echo -e "${RED}节点名 $node_tag 已存在（并发冲突），本次添加已取消${R}"
            exit 1  # 子 shell 内 exit，仅终止本锁块
        fi


        local node_json=$(jq -n \
          --arg tag "$node_tag" \
          --argjson port $port \
          --arg uuid "$uuid" \
          --arg listen "$listen_addr" \
          '{
            tag: $tag,
            type: "vless",
            listen: $listen,
            listen_port: $port,
            users: [{uuid: $uuid}]
          }')

        # 用 jq 生成新配置到临时文件；检查 jq 退出码作为纵深防御
        if ! jq --argjson node "$node_json" '.inbounds += [$node]' "$SB_CONF" > "$SB_CONF.tmp" 2>/dev/null; then
            echo -e "${RED}❌ jq 生成新配置失败，原配置未改动${R}" >&2
            cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
            rm -f "$SB_CONF.tmp"
            exit 1
        fi

        if $SB_BIN check -c "$SB_CONF.tmp" > "$CHECK_LOG" 2>&1; then
            # 用 helper 写配置：处理软链 + mv 失败
            if ! sb_write_conf_atomic "$SB_CONF.tmp" "$SB_CONF"; then
                cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
                exit 1
            fi
            open_port $port

            cat > "${META_DIR}/${node_tag}.json" <<EOF
{"uuid":"$uuid","port":$port}
EOF

            # 节点链接在 systemctl restart 之前打印（参见 reality 同样说明）
            echo -e "${G}✅ VLESS-TCP 部署成功！${R}"
            local link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=none&type=tcp&headerType=none#$(urlencode "$node_tag")"
            echo -e "${C}节点链接: ${link}${R}"

            systemctl restart sing-box
            sleep 2
            if ! systemctl is-active --quiet sing-box; then
                echo -e "${RED}❌ Sing-Box 启动失败！可能是端口冲突，正在回滚配置...${R}" >&2
                journalctl -u sing-box -n 10 --no-pager >&2
                cp "${SB_CONF}.bak" "$SB_CONF"
                close_port $port
                rm -f "${META_DIR}/${node_tag}.json"
                systemctl restart sing-box
                echo -e "${RED}❌ 节点已回滚，链接暂不可用${R}" >&2
            fi
        else
            echo -e "${RED}❌ 校验失败，错误详情：${R}"
            cat "$CHECK_LOG"
            cp "${SB_CONF}.bak" "$SB_CONF"
            rm -f "$SB_CONF.tmp"
        fi
    ) 200>"$SB_CONF_LOCK"
    read -r -s -n 1 -p ""
}

sb_add_hysteria2() {
    sb_check || return
    local server_ip=$(get_my_ip)
    if [ -z "$server_ip" ]; then
        echo -e "${RED}❌ 无法获取服务器 IP（网络不可达），请检查网络后重试${R}"
        read -r -s -n 1 -p ""
        return 1
    fi
    local listen_addr=$(sb_listen_addr)
    echo -e "${Y}设置 Hysteria2 端口${R}"
    local port
    port=$(input_custom_port) || return 1
    local pass=$($SB_BIN generate rand --hex 16)
    local sni="www.bing.com"
    local cert_dir="/etc/sing-box/certs/hy2-${port}"
    local default_tag="hysteria2-${port}"
    local node_tag
    node_tag=$(input_custom_tag "$default_tag") || return 1

    # flock 检测
    if ! (exec 200>"$SB_CONF_LOCK") 2>/dev/null; then
        echo -e "${RED}❌ 无法创建锁文件 $SB_CONF_LOCK，已取消${R}"
        return 1
    fi
    (
        flock -x 200 || { echo -e "${RED}❌ flock 获取锁失败，并发保护失效，已取消${R}" >&2; exit 1; }
        cp "$SB_CONF" "${SB_CONF}.bak"
        # 锁内复查：input_custom_tag 的重名检查在锁外，并发添加同名节点有竞态窗口
        if jq -e --arg t "$node_tag" '((.inbounds // []) + (.outbounds // []) | map(select(.tag==$t)) | length) > 0' "$SB_CONF" >/dev/null 2>&1; then
            echo -e "${RED}节点名 $node_tag 已存在（并发冲突），本次添加已取消${R}"
            exit 1  # 子 shell 内 exit，仅终止本锁块
        fi
        # 证书在锁内、重名检查通过后生成：避免命名处 Ctrl+C 或并发退出时残留
        mkdir -p "$cert_dir"
        openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
        openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=${sni}" 2>/dev/null
        chmod 600 "${cert_dir}/key.pem" 2>/dev/null  # 私钥按 umask 生成常为 0644，收紧为仅属主可读写


        local node_json=$(jq -n \
          --arg tag "$node_tag" \
          --argjson port $port \
          --arg pass "$pass" \
          --arg cert "${cert_dir}/cert.pem" \
          --arg key "${cert_dir}/key.pem" \
          --arg listen "$listen_addr" \
          --arg sni "$sni" \
          '{
            tag: $tag,
            type: "hysteria2",
            listen: $listen,
            listen_port: $port,
            users: [{password: $pass}],
            tls: {
              enabled: true,
              server_name: $sni,
              alpn: ["h3"],
              certificate_path: $cert,
              key_path: $key
            },
            ignore_client_bandwidth: false
          }')

        # 用 jq 生成新配置到临时文件；检查 jq 退出码作为纵深防御
        if ! jq --argjson node "$node_json" '.inbounds += [$node]' "$SB_CONF" > "$SB_CONF.tmp" 2>/dev/null; then
            echo -e "${RED}❌ jq 生成新配置失败，原配置未改动${R}" >&2
            cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
            rm -f "$SB_CONF.tmp"
            rm -rf "$cert_dir"
            exit 1
        fi

        if $SB_BIN check -c "$SB_CONF.tmp" > "$CHECK_LOG" 2>&1; then
            # 用 helper 写配置：处理软链 + mv 失败
            if ! sb_write_conf_atomic "$SB_CONF.tmp" "$SB_CONF"; then
                cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
                rm -rf "$cert_dir"
                exit 1
            fi
            open_port $port

            # 节点链接在 systemctl restart 之前打印（参见 reality 同样说明）
            echo -e "${G}✅ Hysteria2 部署成功！${R}"
            local link="hysteria2://${pass}@${server_ip}:${port}?security=tls&sni=${sni}&alpn=h3&insecure=1#$(urlencode "$node_tag")"
            echo -e "${C}节点链接: ${link}${R}"

            systemctl restart sing-box
            sleep 2
            if ! systemctl is-active --quiet sing-box; then
                echo -e "${RED}❌ Sing-Box 启动失败！正在回滚配置...${R}" >&2
                journalctl -u sing-box -n 10 --no-pager >&2
                cp "${SB_CONF}.bak" "$SB_CONF"
                close_port $port
                rm -rf "$cert_dir"
                systemctl restart sing-box
                echo -e "${RED}❌ 节点已回滚，链接暂不可用${R}" >&2
            fi
        else
            echo -e "${RED}❌ 校验失败，错误详情：${R}"
            cat "$CHECK_LOG"
            cp "${SB_CONF}.bak" "$SB_CONF"
            rm -f "$SB_CONF.tmp"
            rm -rf "$cert_dir"
        fi
    ) 200>"$SB_CONF_LOCK"
    read -r -s -n 1 -p ""
}

sb_del_node() {
    sb_check || return

    local tags=()
    mapfile -t tags < <(jq -r '.inbounds[].tag' "$SB_CONF" 2>/dev/null)
    if [ ${#tags[@]} -eq 0 ]; then
        echo -e "${Y}当前没有任何节点可删除。${R}"
        read -r -s -n 1 -p ""
        return
    fi

    echo -e "${Y}当前已有节点，请选择要删除的节点序号，或直接输入端口号删除：${R}"
    local i=1
    for tag in "${tags[@]}"; do
        echo -e "  ${G}[$i]${R} $tag"
        ((i++))
    done
    echo -e "  ${H}[0] 返回${R}"

    local c=""
    if ! read -r -e -p "请选择: " c; then
        echo "" >&2; echo -e "${RED}错误：输入 EOF，已取消${R}" >&2; return 1
    fi
    if [ "$c" == "0" ] || [ -z "$c" ]; then return; fi

    local tag=""
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#tags[@]} ]; then
        tag="${tags[$((c-1))]}"
    else
        tag=$(jq -r --arg p "$c" '.inbounds[] | select(.listen_port==($p|tonumber)) | .tag' "$SB_CONF" 2>/dev/null)
    fi

    if [ -z "$tag" ]; then
        echo -e "${RED}未找到对应的节点${R}"
        read -r -s -n 1 -p ""
        return
    fi

    local port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag==$t) | .listen_port' "$SB_CONF")
    local type=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag==$t) | .type' "$SB_CONF")

    # flock 检测
    if ! (exec 200>"$SB_CONF_LOCK") 2>/dev/null; then
        echo -e "${RED}❌ 无法创建锁文件 $SB_CONF_LOCK，已取消${R}"
        return 1
    fi
    (
        flock -x 200 || { echo -e "${RED}❌ flock 获取锁失败，并发保护失效，已取消${R}" >&2; exit 1; }
        cp "$SB_CONF" "${SB_CONF}.bak"

        # 用 jq 生成新配置；检查 jq 退出码
        if ! jq --arg t "$tag" 'del(.inbounds[] | select(.tag==$t))' "$SB_CONF" > "$SB_CONF.tmp" 2>/dev/null; then
            echo -e "${RED}❌ jq 生成删除后的配置失败，原配置未改动${R}" >&2
            cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
            rm -f "$SB_CONF.tmp"
            exit 1
        fi

        if $SB_BIN check -c "$SB_CONF.tmp" > "$CHECK_LOG" 2>&1; then
            # 用 helper 写配置：处理软链 + mv 失败
            if ! sb_write_conf_atomic "$SB_CONF.tmp" "$SB_CONF"; then
                cp "${SB_CONF}.bak" "$SB_CONF" 2>/dev/null
                exit 1
            fi

            # 删除成功提示在 systemctl restart 之前打印（节点配置已从磁盘移除）
            echo -e "${G}✅ 节点 $tag 已从配置删除！${R}"
            systemctl restart sing-box
            sleep 2
            if systemctl is-active --quiet sing-box; then
                # 健康确认通过后再做清理：若先清理后回滚，端口/meta/证书会被误删且无法恢复
                close_port $port
                rm -f "${META_DIR}/${tag}.json"
                if [ "$type" == "hysteria2" ]; then
                    rm -rf "/etc/sing-box/certs/hy2-${port}"
                fi
                echo -e "${G}✅ 节点清理完成${R}"
            else
                echo -e "${RED}❌ Sing-Box 启动失败，正在回滚配置...${R}" >&2
                journalctl -u sing-box -n 10 --no-pager >&2
                cp "${SB_CONF}.bak" "$SB_CONF"
                systemctl restart sing-box
                echo -e "${RED}❌ 节点已回滚（未删除）${R}" >&2
            fi
        else
            echo -e "${RED}❌ 删除节点失败，错误详情：${R}"
            cat "$CHECK_LOG"
            cp "${SB_CONF}.bak" "$SB_CONF"
            rm -f "$SB_CONF.tmp"
        fi
    ) 200>"$SB_CONF_LOCK"
    read -r -s -n 1 -p ""
}

sb_manage_ports() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║          🔥 端口防火墙管理 (TCP+UDP)       ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo -e "    ${Y}[1] 放行指定端口${R}"
        echo -e "    ${Y}[2] 关闭指定端口${R}"
        echo -e "    ${H}[0] 返回上一级${R}"
        read -r -e -p "  请选择: " c
        case "$c" in
            1) 
                read -r -e -p "请输入要放行的端口号: " p
                if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
                    if open_port $p; then
                        echo -e "${G}✅ 端口 $p 已放行 (TCP+UDP)${R}"
                    else
                        echo -e "${RED}端口 $p 放行未完成${R}"
                    fi
                else
                    echo -e "${RED}端口号无效${R}"
                fi
                read -r -s -n 1 -p ""
                ;;
            2) 
                read -r -e -p "请输入要关闭的端口号: " p
                if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
                    if close_port $p; then
                        echo -e "${G}✅ 端口 $p 已关闭 (TCP+UDP)${R}"
                    else
                        echo -e "${RED}端口 $p 关闭未完成${R}"
                    fi
                else
                    echo -e "${RED}端口号无效${R}"
                fi
                read -r -s -n 1 -p ""
                ;;
            0|"") break ;;
        esac
    done
}

sb_show_links() {
    sb_check || return
    local server_ip=$(get_my_ip)
    if [ -z "$server_ip" ]; then
        echo -e "${RED}警告：无法获取服务器公网 IP，生成的链接中地址为空，请手动替换为你的公网 IP 后再使用${R}"
    fi
    echo -e "\n${Y}===== 节点链接 =====${R}"

    # flock 检测：用共享锁避免读到正在被修改的配置
    if ! (exec 200>"$SB_CONF_LOCK") 2>/dev/null; then
        echo -e "${RED}❌ 无法创建锁文件 $SB_CONF_LOCK，已取消${R}"
        return 1
    fi
    (
        flock -s 200 || { echo -e "${RED}❌ flock 获取共享锁失败，已取消${R}" >&2; exit 1; }

        # VLESS-Reality
        jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .tag' "$SB_CONF" 2>/dev/null | while read -r tag; do
            if [ -n "$tag" ]; then
                if [ ! -f "${META_DIR}/${tag}.json" ]; then
                    # meta 文件缺失时打印警告，不要让节点静默消失
                    echo "# 警告：节点 $tag 的 meta 文件缺失，无法生成链接（节点配置可能已损坏，建议删除后重建）" >&2
                    continue
                fi
                local meta="${META_DIR}/${tag}.json"
                local uuid=$(jq -r '.uuid' "$meta")
                local port=$(jq -r '.port' "$meta")
                local sni=$(jq -r '.sni' "$meta")
                local pub_key=$(jq -r '.public_key' "$meta")
                local short_id=$(jq -r '.short_id' "$meta")
                local flow=$(jq -r '.flow // empty' "$meta")
                local flow_param=""
                if [ -n "$flow" ]; then
                    flow_param="&flow=${flow}"
                fi
                echo "vless://${uuid}@${server_ip}:${port}?encryption=none${flow_param}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#$(urlencode "$tag")"
            fi
        done

        # VLESS-TCP
        jq -r '.inbounds[] | select(.type=="vless" and (.tls == null or .tls == {})) | .tag' "$SB_CONF" 2>/dev/null | while read -r tag; do
            if [ -n "$tag" ]; then
                if [ ! -f "${META_DIR}/${tag}.json" ]; then
                    echo "# 警告：节点 $tag 的 meta 文件缺失，无法生成链接（建议删除后重建）" >&2
                    continue
                fi
                local meta="${META_DIR}/${tag}.json"
                local uuid=$(jq -r '.uuid' "$meta")
                local port=$(jq -r '.port' "$meta")
                echo "vless://${uuid}@${server_ip}:${port}?encryption=none&security=none&type=tcp&headerType=none#$(urlencode "$tag")"
            fi
        done

        # Hysteria2
        jq -r --arg ip "$server_ip" '.inbounds[] | select(.type=="hysteria2") | "hysteria2://" + .users[0].password + "@" + $ip + ":" + (.listen_port|tostring) + "?security=tls&sni=" + (.tls.server_name // "www.bing.com") + "&alpn=h3&insecure=1#" + (.tag | @uri)' "$SB_CONF" 2>/dev/null

    ) 200>"$SB_CONF_LOCK"

    read -r -s -n 1 -p ""
}

sb_menu() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║       Sing-Box 管理面板                   ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo -e "    ${Y}[1] 安装 Sing-Box${R}"
        echo -e "    ${Y}[2] 添加 VLESS-Reality 节点${R}"
        echo -e "    ${Y}[3] 添加 VLESS-TCP 节点${R}"
        echo -e "    ${Y}[4] 添加 Hysteria2 节点${R}"
        echo -e "    ${Y}[5] 查看所有节点链接${R}"
        echo -e "    ${RED}[6] 删除已添加节点 (支持按端口删除)${R}"
        echo -e "    ${C}[7] 手动管理端口放行 (TCP+UDP)${R}"
        echo -e "    ${H}[0] 返回主菜单${R}"
        read -r -e -p "  选择: " c
        case "$c" in
            1) clear; sb_install ;;
            2) clear; sb_add_reality ;;
            3) clear; sb_add_vless_tcp ;;
            4) clear; sb_add_hysteria2 ;;
            5) clear; sb_show_links ;;
            6) clear; sb_del_node ;;
            7) clear; sb_manage_ports ;;
            0|"") break ;;
        esac
    done
}

main_menu() {
    check_env
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║          🎉 MiMi 服务器优化工具箱             ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo -e "    ${Y}[1] 🚀 网络与内核优化 (BBR/XanMod)${R}"
        echo -e "    ${Y}[2] 📦 Sing-Box 管理面板${R}"
        echo -e "    ${H}[0] 退出${R}"
        read -r -e -p "  请选择: " c
        case "$c" in
            1) clear; smart_auto_optimize ;;
            2) clear; sb_menu ;;
            0|"") exit 0 ;;
        esac
    done
}

# ================= 自动创建快捷指令 =================

auto_shortcut() {
    local target="/usr/local/bin/mimi"
    local src="${BASH_SOURCE[0]:-$0}"
    # 兜底下载源（仅当本地源文件找不到时用；curl|bash 在脚本开头已被 exit 1，到不了这里）
    local script_url="https://raw.githubusercontent.com/mimicatcn/mimi/main/smart.sh"
    local tmp_install="" install_source=""
    local install_ok=0
    local src_real=""

    [ "$(id -u)" -ne 0 ] && return 0     # 非 root 跳过

    # 用 realpath 解析 src，做路径等价比较（而非字符串比对）
    # 防止"自身运行 mimi"被误装：bash ./mimi、symlink 别名、相对路径等都解析为同一绝对路径
    if [ -n "$src" ] && [ "$src" != "/dev/fd/0" ] && [ "$src" != "/dev/stdin" ] && [ -f "$src" ]; then
        src_real=$(realpath "$src" 2>/dev/null || echo "$src")
    fi
    # 正在运行的就是 mimi 本身，无需安装，直接返回（防止把仓库版静默覆盖正在跑的版本）
    [ "$src_real" = "$target" ] && return 0

    # 目标已是目录：拒绝，避免把文件塞进去后 chmod 目录假成功
    if [ -d "$target" ]; then
        echo -e "${RED}错误：${target} 是目录而非可执行文件，请手动检查后重试${R}" >&2
        return 1
    fi

    # 临时文件用 PID 标记：本进程只动自己的文件，绝不扫别人的"残留"
    #
    # 历史教训：上一版做了"启动时扫描清理 .yw_install.*"，但实例 A 正在下载时实例 B
    # 启动会把 A 的临时文件当残留删了（A 的数据继续写到已 unlink 的 inode，最终误报
    # "下载为空"）。改用 PID 命名后，本进程只动 .yw_install.<pid>.<XXXXXX>，绝不碰
    # 其他实例的文件——并发安全。
    #
    # 残留清理：本进程的 EXIT trap 会清理自己的临时文件，但 trap 不能捕获 SIGKILL
    # 和断电。这两种情况下会留下一个 .yw_install.<pid>.<XXXXXX> 垃圾文件，本工具
    # 不会自动清理（自动清理必然涉及扫描，扫描就有并发误删风险，两害相权取其轻）。
    # 启动时只做"被动提示"——发现疑似残留就告知用户，绝不主动删除。
    local _tmp_dir _tmp_prefix
    _tmp_dir="$(dirname "$target")"
    _tmp_prefix="${_tmp_dir}/.yw_install.$$"

    tmp_install="$(mktemp "${_tmp_prefix}.XXXXXX")" || {
        echo -e "${RED}错误：无法创建临时文件${R}" >&2
        return 1
    }

    # 立即挂多信号 trap（在检测之前，避免 mktemp 与 trap 之间的毫秒级窗口被杀导致残留）
    #   - 同时挂 EXIT/INT/TERM/HUP：bash 在 wait 子进程（如 curl）时收到 SIGINT，
    #     EXIT trap 不一定触发；显式 trap INT/TERM/HUP 才能保证 Ctrl+C 等中断也清理
    #   - 不覆盖脚本开头 `trap 'rm -f "$CHECK_LOG"' EXIT`，而是组合追加
    #   - 退出码透传：`exit $rc` 保留原退出码
    #   - 末尾追加 rm -f "$CHECK_LOG" 作为 sed 失败时的兜底（CHECK_LOG 是脚本顶层变量）
    #   - 注意：trap 无法捕获 SIGKILL 和断电，那种情况下临时文件会残留，
    #     下次启动会看到下面的"被动提示"，由用户决定是否手动清理
    local _old_trap_body
    _old_trap_body=$(trap -p EXIT | sed -E "s/^trap -- '//; s/' EXIT$//" 2>/dev/null)
    trap 'rc=$?; rm -f "'"${tmp_install}"'" 2>/dev/null; '"${_old_trap_body}"' 2>/dev/null; rm -f "$CHECK_LOG" 2>/dev/null; exit $rc' EXIT INT TERM HUP

    # 被动检测疑似残留（trap 已挂好，本进程自己的临时文件已受保护）
    # 三层过滤避免误报：
    #   1) 严格正则 ^\.yw_install\.[0-9]+\.[A-Za-z0-9]{6}$  ← 纯数字 pid + 恰好 6 字母数字
    #   2) mtime 距今 ≥ 60 秒  ← 60 秒内的可能是其他实例正在使用，绝不报
    #      （curl 下载最长 20 秒，加 40 秒缓冲足够覆盖任何活跃实例）
    #   3) 跳过本进程的 tmp_install（精确路径比对，不是 pid 通配——避免 PID 复用残留隐身）
    #
    # 不再建议任何 rm 通配命令：
    #   - pgrep -f mimi 守卫失效：残留只产生于跑 .sh 文件的实例（cmdline 不含 yw）
    #   - 子串匹配过宽：会误中无关进程甚至自身（bash -c 内会自匹配）
    #   - rm 通配不分年龄：会删掉另一实例刚建的临时文件
    #   只列出具体路径，让用户逐个手动删除
    local _stale="" _now _f _mtime _age _name
    _now=$(date +%s)
    for _f in "${_tmp_dir}"/.yw_install.*.*; do
        [ -f "$_f" ] || continue
        [ "$_f" = "$tmp_install" ] && continue   # 跳过本进程刚创建的（精确路径比对）
        _name="${_f##*/}"
        # 严格正则：.yw_install.<纯数字 pid>.<恰好 6 个字母数字>
        [[ "$_name" =~ ^\.yw_install\.[0-9]+\.[A-Za-z0-9]{6}$ ]] || continue
        # mtime 在 60 秒内的可能是其他实例正在使用，跳过（避免并发误报）
        _mtime=$(stat -c %Y "$_f" 2>/dev/null) || continue
        _age=$((_now - _mtime))
        [ "$_age" -lt 60 ] && continue
        _stale="${_stale} $_f"
    done
    if [ -n "$_stale" ]; then
        local _count
        _count=$(echo "$_stale" | wc -w)
        echo -e "${Y}提示：检测到 ${_count} 个疑似残留的临时文件（已存在超过 60 秒）：${R}" >&2
        echo "$_stale" | tr ' ' '\n' | grep -v '^$' | sed 's/^/  /' >&2
        echo -e "${Y}  这些可能是上次异常退出（kill -9 / 断电）留下的，也可能是其他实例正在使用。${R}" >&2
        echo -e "${Y}  本工具不自动删除（避免并发误删）。如确认这些具体文件是残留，可逐个手动删除：${R}" >&2
        echo -e "${C}  rm <上方列出的具体文件路径>${R}" >&2
    fi

    # 1) 优先本地文件运行：装的就是用户正在跑的版本（保证一致）
    if [ -n "$src_real" ] && [ -f "$src_real" ]; then
        if cp -f "$src_real" "$tmp_install" 2>/dev/null; then
            # 末尾换行符：源若缺，补一个，避免后续 cat 拼接粘行
            [ -n "$(tail -c1 "$tmp_install" 2>/dev/null)" ] && printf '\n' >> "$tmp_install"
            # 本地副本也做语法校验，避免装到坏版本
            if bash -n "$tmp_install" 2>/dev/null; then
                install_ok=1
                install_source="本地脚本"
            else
                echo -e "${RED}错误：源脚本语法校验失败，未覆盖现有 mimi${R}" >&2
                rm -f "$tmp_install"
                return 1
            fi
        else
            # 本地 cp 失败不静默：明确告知用户改走下载，避免装的不是正在跑的版本还看似成功
            echo -e "${Y}提示：本地源读取失败（$src_real），改走 GitHub 下载兜底${R}" >&2
        fi
    fi

    # 2) 兜底：从 GitHub 下载到临时文件 → 校验 → 原子安装
    #    注：curl|bash 用户在脚本开头已被 exit 1 拒绝，到不了这里；本分支实际服务粘贴执行场景
    if [ "$install_ok" -ne 1 ]; then
        local http_code curl_rc
        http_code=$(curl -sSL -w '%{http_code}' --max-time 20 -o "$tmp_install" "$script_url" 2>/dev/null)
        curl_rc=$?

        # 区分错误码，避免把"传输中断"误报成"不可达"
        #   6 = DNS 解析失败（真不可达）
        #   7 = 连接失败/拒绝（真不可达）
        #  18 = 传输中途断开（服务器已连接、已传部分，常见于大文件下载被打断）
        #  28 = 超时
        # 其他 = 笼统"下载失败"
        if [ "$curl_rc" -ne 0 ]; then
            case "$curl_rc" in
                6|7)  echo -e "${Y}提示：GitHub 不可达（curl 退出码 $curl_rc，DNS 或连接失败），跳过 mimi 快捷指令创建${R}" >&2 ;;
                18)   echo -e "${Y}提示：GitHub 传输中断（已连接但中途断开），跳过 mimi 快捷指令创建${R}" >&2 ;;
                28)   echo -e "${Y}提示：从 GitHub 拉取超时（>20s），跳过 mimi 快捷指令创建${R}" >&2 ;;
                *)    echo -e "${Y}提示：GitHub 下载失败（curl 退出码 $curl_rc），跳过 mimi 快捷指令创建${R}" >&2 ;;
            esac
            echo -e "    手动安装：curl -fsSL $script_url -o /usr/local/bin/mimi && chmod 755 /usr/local/bin/mimi" >&2
            rm -f "$tmp_install"
            return 1
        fi
        if [ "$http_code" != "200" ]; then
            echo -e "${Y}提示：GitHub 返回 HTTP $http_code（非 200），跳过 mimi 快捷指令创建${R}" >&2
            rm -f "$tmp_install"
            return 1
        fi
        # 空文件 / 残片：拒绝
        if [ ! -s "$tmp_install" ]; then
            echo -e "${Y}提示：下载内容为空，跳过 mimi 快捷指令创建${R}" >&2
            rm -f "$tmp_install"
            return 1
        fi

        # 末尾换行符
        [ -n "$(tail -c1 "$tmp_install" 2>/dev/null)" ] && printf '\n' >> "$tmp_install"

        # 内容校验：必须是 bash 脚本且语法正确，防止 HTML 错误页被装成 mimi（假成功）
        if ! head -1 "$tmp_install" | grep -q '^#!.*bash'; then
            echo -e "${RED}错误：下载内容非 bash 脚本（疑似错误页），未安装${R}" >&2
            rm -f "$tmp_install"
            return 1
        fi
        if ! bash -n "$tmp_install" 2>/dev/null; then
            echo -e "${RED}错误：下载脚本语法校验失败（疑似内容损坏），未安装${R}" >&2
            rm -f "$tmp_install"
            return 1
        fi
        install_ok=1
        install_source="GitHub 仓库当前版本（可能与正在运行的版本不一致）"
    fi

    # 3) 原子安装：chmod + mv -f 替换 target
    #    - 临时文件已与 target 同目录，mv -f 走内核 rename(2)：原子替换，无"目标不存在"空窗
    #    - 若 target 是 symlink，rename(2) 替换 symlink 本身（POSIX 标准），不写穿邻居
    #    - mv 失败时 tmp_install 仍是独立文件，target 完好无损
    chmod 755 "$tmp_install" 2>/dev/null
    if mv -f "$tmp_install" "$target" 2>/dev/null; then
        echo -e "${G}✅ mimi 快捷指令已创建（/usr/local/bin/mimi，来源：${install_source}）${R}"
        return 0
    else
        echo -e "${RED}错误：安装到 $target 失败（原 mimi 未被修改）${R}" >&2
        rm -f "$tmp_install"
        return 1
    fi
}

auto_shortcut
main_menu
