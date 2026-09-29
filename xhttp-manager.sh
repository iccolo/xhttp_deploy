#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
INFO_FILE="/usr/local/etc/xray/env_info.env"

# ===== 自安装 / 自更新配置 =====
# 脚本托管仓库，用于 xhttp update 自更新
REPO="${XHTTP_REPO:-iccolo/xhttp_deploy}"
INSTALL_PATH="/usr/local/bin/xhttp"
# 多个源依次尝试（raw 被墙时自动走 jsDelivr CDN 镜像）
SCRIPT_URLS=(
    "https://raw.githubusercontent.com/${REPO}/main/xhttp-manager.sh"
    "https://cdn.jsdelivr.net/gh/${REPO}@main/xhttp-manager.sh"
    "https://fastly.jsdelivr.net/gh/${REPO}@main/xhttp-manager.sh"
)

# 从远端拉取脚本本体，成功返回 0
download_self() {
    local out=$1 u
    for u in "${SCRIPT_URLS[@]}"; do
        if curl -fsSL --connect-timeout 10 "$u" -o "$out" 2>/dev/null && [[ -s "$out" ]]; then
            echo -e "${GREEN}已获取：$u${PLAIN}"
            return 0
        fi
    done
    echo -e "${RED}下载失败：请检查网络，或确认 REPO(${REPO}) 与分支(main)是否正确。${PLAIN}"
    return 1
}

# 安装为可全局调用的 xhttp 命令
self_install() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：安装需要 root 权限！${PLAIN}" && exit 1

    local TMP
    TMP=$(mktemp)
    if ! download_self "$TMP"; then
        rm -f "$TMP"
        exit 1
    fi
    if ! bash -n "$TMP"; then
        echo -e "${RED}下载的脚本语法校验失败，已放弃安装。${PLAIN}"
        rm -f "$TMP"
        exit 1
    fi

    install -m 0755 "$TMP" "$INSTALL_PATH"
    rm -f "$TMP"
    echo -e "${GREEN}\n安装完成！以后在任意位置直接运行：${PLAIN} xhttp"
    echo -e "${YELLOW}升级到最新版：${PLAIN} xhttp update"

    # 交互式安装时顺手进菜单，非交互（curl | bash）则直接结束
    if [[ -t 0 ]]; then
        read -p "是否立即运行 xhttp 菜单？(y/n) [默认 y]: " RUN_NOW
        RUN_NOW=${RUN_NOW:-y}
        if [[ "$RUN_NOW" == "y" || "$RUN_NOW" == "Y" ]]; then
            exec bash "$INSTALL_PATH"
        fi
    fi
}

# 更新自身到最新版本
self_update() {
    local SELF TMP
    SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
    TMP=$(mktemp)

    # 只在已安装到标准路径时就地更新，避免误覆盖其它文件（如 bash 自身）
    if [[ "$SELF" != "$INSTALL_PATH" ]]; then
        echo -e "${YELLOW}当前运行的是 $SELF（非 $INSTALL_PATH），将把最新版安装到 $INSTALL_PATH${PLAIN}"
        self_install
        rm -f "$TMP"
        return 0
    fi

    if ! download_self "$TMP"; then
        rm -f "$TMP"
        return 1
    fi
    if ! bash -n "$TMP"; then
        echo -e "${RED}新版本语法校验失败，已放弃更新（当前版本未改动）。${PLAIN}"
        rm -f "$TMP"
        return 1
    fi
    if cmp -s "$TMP" "$SELF"; then
        echo -e "${GREEN}当前已是最新版本，无需更新。${PLAIN}"
        rm -f "$TMP"
        return 0
    fi

    # 用 cat 覆盖而不是 mv，保留原文件的权限与 inode
    cat "$TMP" > "$SELF"
    chmod +x "$SELF"
    rm -f "$TMP"
    echo -e "${GREEN}更新完成！${PLAIN}"

    # 覆盖正在运行的脚本后必须立刻重新加载，否则会继续执行旧内容
    if [[ -t 0 ]]; then
        echo -e "${YELLOW}正在重启脚本...${PLAIN}"
        exec bash "$SELF"
    fi
}

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 安装基础依赖
install_deps() {
    echo -e "${GREEN}检查并安装所需基础依赖 (jq, curl, qrencode)...${PLAIN}"
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y jq curl qrencode openssl
    elif command -v yum &>/dev/null; then
        yum install -y epel-release && yum install -y jq curl qrencode openssl
    fi
}

# 生成 REALITY 密钥对（兼容不同 Xray 版本的输出格式差异，stderr 一并捕获）
gen_reality_keys() {
    local KEYS
    KEYS=$(/usr/local/bin/xray x25519 2>&1)
    # 密钥可能是标准 base64(带 =) 或 base64url(含 - _ )，两种字符集都要覆盖
    PRIKEY=$(echo "$KEYS" | grep -iE "private[[:space:]]*key" | grep -oE '[A-Za-z0-9+/_=-]{40,}' | head -1)
    PUBKEY=$(echo "$KEYS" | grep -iE "public[[:space:]]*key"  | grep -oE '[A-Za-z0-9+/_=-]{40,}' | head -1)

    if [[ -z "$PRIKEY" || -z "$PUBKEY" ]]; then
        echo -e "${RED}错误：REALITY 密钥对解析失败，xray x25519 的原始输出如下：${PLAIN}"
        echo "$KEYS"
        echo -e "${YELLOW}请手动执行 'xray x25519' 并把结果粘贴到下面（私钥留空则放弃操作）。${PLAIN}"
        read -p "Private Key: " PRIKEY
        if [[ -z "$PRIKEY" ]]; then
            PRIKEY=""; PUBKEY=""
            return 1
        fi
        read -p "Public  Key: " PUBKEY
        if [[ -z "$PUBKEY" ]]; then
            PRIKEY=""; PUBKEY=""
            return 1
        fi
    fi
    return 0
}

# 检查 TCP 端口是否被占用
port_in_use() {
    local p=$1
    if command -v ss &>/dev/null; then
        ss -H -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    elif command -v netstat &>/dev/null; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    elif command -v lsof &>/dev/null; then
        lsof -nP -iTCP:"$p" -sTCP:LISTEN &>/dev/null
    else
        return 1
    fi
}

# 规范化用户输入的域名：去掉协议前缀、路径、端口和空白，只保留主机名
normalize_host() {
    local h=$1
    h=$(echo "$h" | tr -d '[:space:]')
    h=${h#http://}
    h=${h#https://}
    h=${h%%/*}
    h=${h%%:*}
    echo "$h"
}

# ===== 伪装域名自动探测（REALITY 要求目标站点支持 TLS 1.3 + X25519）=====

# 探测 VPS 归属（IP / 运营商 / ASN）
detect_vps_info() {
    local JSON
    JSON=$(curl -s4 --connect-timeout 8 --max-time 12 https://ipinfo.io/json 2>/dev/null)
    VPS_IP=$(echo "$JSON" | jq -r '.ip // empty' 2>/dev/null)
    VPS_ORG=$(echo "$JSON" | jq -r '.org // empty' 2>/dev/null)
    VPS_ASN=$(echo "$VPS_ORG" | grep -oE 'AS[0-9]+' | head -1 | sed 's/AS//')
}

# 单个域名是否支持 TLS 1.3
probe_domain() {
    local out
    out=$(timeout 8 /usr/local/bin/xray tls ping "$1" 2>&1)
    echo "$out" | grep -qE 'TLS[[:space:]]*1\.3' || return 1
    return 0
}

# 方式一：从证书日志反查同网段 / 同运营商的真实域名并实测
scan_domains_crt() {
    local RAW D CLEAN_ORG COUNT=0
    [[ -z "$VPS_IP" ]] && return 0

    RAW=$(curl -s --connect-timeout 8 --max-time 15 "https://crt.sh/?q=${VPS_IP%.*}.0/24&output=json" 2>/dev/null \
        | jq -r '.[].name_value' 2>/dev/null | sed 's/\*\.//g' | sort -u | head -n 15)

    if [[ -z "$RAW" ]]; then
        CLEAN_ORG=$(echo "$VPS_ORG" | sed -E 's/AS[0-9]+ //; s/,//g' | awk '{print $1}')
        if [[ -n "$CLEAN_ORG" ]]; then
            RAW=$(curl -s --connect-timeout 8 --max-time 15 "https://crt.sh/?q=%25.${CLEAN_ORG}.com&output=json" 2>/dev/null \
                | jq -r '.[].name_value' 2>/dev/null | sed 's/\*\.//g' | sort -u | head -n 10)
        fi
    fi

    for D in $RAW; do
        [[ "$D" == *" "* ]] && continue
        [[ ${#D} -gt 35 || "$D" != *.* ]] && continue
        if probe_domain "$D"; then
            echo "$D"
            COUNT=$((COUNT + 1))
            [[ $COUNT -ge 5 ]] && break
        fi
    done
}

# 方式二（兜底）：按运营商/机房推荐常用域名并实测
preset_domains() {
    local LIST D
    case "$VPS_ORG" in
        *DigitalOcean*)   LIST="images.digitalocean.com assets.digitalocean.com cloud.digitalocean.com" ;;
        *Amazon*|*AWS*)   LIST="aws.amazon.com s3.amazonaws.com cloudfront.net" ;;
        *Linode*|*Akamai*) LIST="login.linode.com assets.linode.com speedtest.tokyo2.linode.com" ;;
        *Cloudflare*)     LIST="cdnjs.cloudflare.com dash.cloudflare.com workers.dev" ;;
        *Tencent*|*Alibaba*) LIST="img3.doubanio.com static.zhihu.com images.unsplash.com" ;;
        *)                LIST="images.unsplash.com cdn.pixabay.com swdist.apple.com dl.delivery.mp.microsoft.com www.microsoft.com" ;;
    esac

    for D in $LIST; do
        probe_domain "$D" && echo "$D"
    done
}

# 自动探测并挑选伪装域名，结果写入 PICKED_SNI
auto_pick_sni() {
    PICKED_SNI=""
    echo -e "${GREEN}\n>>> 正在检测 VPS 网络归属...${PLAIN}"
    detect_vps_info
    echo -e "IP：${VPS_IP:-未知}   运营商：${VPS_ORG:-未知}   ASN：${VPS_ASN:-未知}"

    local CAND_STR="" d
    echo -e "${GREEN}>>> 方式一：从证书日志反查同网段/同运营商域名并实测 TLS 1.3...${PLAIN}"
    CAND_STR=$(scan_domains_crt)

    if [[ -z "$CAND_STR" ]]; then
        echo -e "${YELLOW}未反查到可用域名，启用兜底：按运营商推荐常用域名并实测...${PLAIN}"
        CAND_STR=$(preset_domains)
    fi

    if [[ -z "$CAND_STR" ]]; then
        echo -e "${RED}两种方式均未找到支持 TLS 1.3 的域名，请检查网络或手动输入。${PLAIN}"
        return 1
    fi

    local -a CAND=()
    while IFS= read -r d; do
        [[ -n "$d" ]] && CAND+=("$d")
    done <<< "$CAND_STR"

    echo -e "${GREEN}\n可用的伪装域名：${PLAIN}"
    local i
    for i in "${!CAND[@]}"; do
        echo -e "  $((i + 1)). ${CAND[$i]}"
    done

    local IDX
    read -p "输入序号选择 [默认 1]: " IDX
    IDX=${IDX:-1}
    [[ ! "$IDX" =~ ^[0-9]+$ ]] && IDX=1
    (( IDX < 1 || IDX > ${#CAND[@]} )) && IDX=1
    PICKED_SNI="${CAND[$((IDX - 1))]}"
    echo -e "${GREEN}已选择：$PICKED_SNI${PLAIN}"
    return 0
}

# 获取公网 IP
get_ip() {
    IP=$(curl -s4 -m 5 ifconfig.me || curl -s4 -m 5 api.ipify.org)
    if [[ -z "$IP" ]]; then
        echo -e "${RED}无法获取 VPS 公网 IP，请手动输入！${PLAIN}"
        read -p "请输入 VPS 公网 IP: " IP
    fi
}

# 部署并配置 XHTTPS
install_xhttp() {
    install_deps
    get_ip

    echo -e "${GREEN}\n>>> 开始安装最新版 Xray-core...${PLAIN}"
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

    if [[ ! -f "/usr/local/bin/xray" ]]; then
        echo -e "${RED}Xray 安装失败，请检查网络或日志！${PLAIN}"
        exit 1
    fi

    echo -e "${GREEN}\n>>> 开始配置节点的关键凭证...${PLAIN}"
    
    # 输入或自动生成端口（含端口占用检测）
    while true; do
        read -p "请输入 XHTTP 服务端口 [默认 443]: " PORT
        PORT=${PORT:-443}
        if ! port_in_use "$PORT"; then
            break
        fi
        echo -e "${RED}端口 $PORT 已被其它进程占用：${PLAIN}"
        ss -tlnp "sport = :$PORT" 2>/dev/null || lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null
        read -p "直接回车换一个端口，或输入 y 强制使用 $PORT: " ANS
        [[ "$ANS" == "y" || "$ANS" == "Y" ]] && break
    done

    # 输入伪装域名：留空则自动探测同网段/同运营商的合规域名
    while true; do
        read -p "请输入 REALITY 伪装域名（留空=自动探测推荐域名）: " SNI
        if [[ -z "$SNI" ]]; then
            if ! auto_pick_sni; then
                echo -e "${YELLOW}自动探测未获得可用域名，请手动输入。${PLAIN}"
                continue
            fi
            SNI="$PICKED_SNI"
        fi
        SNI=$(normalize_host "$SNI")

        echo -e "${YELLOW}正在校验 $SNI 的 TLS 握手（REALITY 回落依赖它）...${PLAIN}"
        PING_OUT=$(timeout 10 /usr/local/bin/xray tls ping "$SNI" 2>&1)
        echo "$PING_OUT"
        if ! echo "$PING_OUT" | grep -qE 'TLS[[:space:]]*1\.3'; then
            echo -e "${RED}警告：$SNI 握手失败或不支持 TLS 1.3，REALITY 无法回落（客户端会报 EOF）。${PLAIN}"
            read -p "强制使用请输入 y，换一个请输入 n [默认 n]: " FORCE_SNI
            if [[ "$FORCE_SNI" == "y" || "$FORCE_SNI" == "Y" ]]; then
                break
            fi
            continue
        fi
        echo -e "${GREEN}域名 $SNI 校验通过（TLS 1.3）！${PLAIN}"
        break
    done

    # 输入或生成自定义 Path
    read -p "请输入 XHTTP 自定义路径 [默认 /xhttp-node]: " XPATH
    XPATH=${XPATH:-/xhttp-node}
    [[ "${XPATH:0:1}" != "/" ]] && XPATH="/$XPATH"

    # 生成安全凭证
    UUID=$(/usr/local/bin/xray uuid 2>&1 | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1)
    [[ -z "$UUID" ]] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    if [[ -z "$UUID" ]]; then
        echo -e "${RED}UUID 生成失败，已终止部署。${PLAIN}"
        return 1
    fi

    if ! gen_reality_keys; then
        echo -e "${RED}REALITY 密钥对缺失，已终止部署（privateKey 为空 Xray 无法启动）。${PLAIN}"
        return 1
    fi

    SHORTID=$(openssl rand -hex 8)

    # 写入 JSON 配置
    echo -e "${GREEN}正在写入配置文件 /usr/local/etc/xray/config.json ...${PLAIN}"
    mkdir -p /usr/local/etc/xray
    cat << JSONEOF > $CONFIG_FILE
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIKEY",
          "shortIds": [
            "$SHORTID"
          ]
        },
        "xhttpSettings": {
          "mode": "stream-up",
          "path": "$XPATH",
          "extra": {
            "scMaxConcurrentPosts": 100
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
JSONEOF

    # 保存公钥环境变量
    cat << ENVEOF > $INFO_FILE
PUBKEY="$PUBKEY"
ENVEOF

    # 开放系统防火墙端口
    if command -v ufw &>/dev/null; then
        ufw allow ${PORT}/tcp &>/dev/null
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
    fi

    # 写入后自检：JSON 语法 + Xray 配置合法性
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}配置文件 JSON 语法错误：${PLAIN}"
        jq empty "$CONFIG_FILE"
        return 1
    fi

    echo -e "${GREEN}REALITY 私钥已写入：${PRIKEY:0:8}...（长度 ${#PRIKEY}）${PLAIN}"

    echo -e "${GREEN}正在校验 Xray 配置...${PLAIN}"
    TEST_OUT=$(/usr/local/bin/xray -test -c "$CONFIG_FILE" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Xray 配置校验失败：${PLAIN}"
        echo "$TEST_OUT"
        return 1
    fi
    echo "$TEST_OUT" | tail -2

    # 重装后 service 可能被官方脚本覆盖为 nobody，特权端口下需先修正运行用户
    ensure_service_permission

    # 重启服务并检查运行状态
    systemctl restart xray
    systemctl enable xray &>/dev/null

    for i in {1..5}; do
        sleep 1
        systemctl is-active --quiet xray && break
    done

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}\n=========================================="
        echo -e "         XHTTP 服务部署成功并已启动！"
        echo -e "==========================================${PLAIN}"
        show_link
    else
        echo -e "${RED}Xray 启动失败！${PLAIN}"
        echo -e "${YELLOW}>>> 最近 20 条日志：${PLAIN}"
        journalctl -u xray -n 20 --no-pager
        diag_service
    fi
}

# 显示节点导入链接和二维码
show_link() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}未找到 Xray 配置文件，请先部署！${PLAIN}"
        return
    fi

    get_ip
    [[ -f $INFO_FILE ]] && source $INFO_FILE

    PORT=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)
    SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $CONFIG_FILE)
    SID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG_FILE)
    MODE=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode' $CONFIG_FILE)
    RAW_PATH=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' $CONFIG_FILE)
    PATH_ENC=$(echo -n "$RAW_PATH" | jq -sRr @uri)

    if [[ -z "$PUBKEY" ]]; then
        read -p "未找到记录的 Public Key，请输入对应公钥: " PUBKEY
    fi

    URL="vless://${UUID}@${IP}:${PORT}?type=xhttp&security=reality&encryption=none&pbk=${PUBKEY}&fp=chrome&sni=${SNI}&sid=${SID}&mode=${MODE}&path=${PATH_ENC}#XHTTPS-Node"

    echo -e "\n${YELLOW}------------------ v2rayNG / 客户端一键导入链接 ------------------${PLAIN}"
    echo -e "${GREEN}${URL}${PLAIN}"
    echo -e "${YELLOW}------------------------------------------------------------------${PLAIN}\n"
    
    echo -e "终端二维码（手机 v2rayNG 直接扫码导入）："
    qrencode -t ansiutf8 "$URL"
}

# 写入新的 SNI 并重启（含 TLS 校验与配置校验）
apply_sni() {
    local NEW_SNI PING_OUT TMP_JSON TEST_OUT
    NEW_SNI=$(normalize_host "$1")
    if [[ -z "$NEW_SNI" ]]; then
        echo -e "${YELLOW}域名无效，已取消。${PLAIN}"
        return 1
    fi
    echo -e "${BLUE}规范化后的域名：$NEW_SNI${PLAIN}"

    # REALITY 依赖目标站点的 TLS 回落，握手不通或不支持 X25519 都会导致客户端报 EOF
    echo -e "${YELLOW}正在校验 $NEW_SNI 的 TLS 握手（REALITY 回落依赖它）...${PLAIN}"
    PING_OUT=$(timeout 10 /usr/local/bin/xray tls ping "$NEW_SNI" 2>&1)
    echo "$PING_OUT"
    if ! echo "$PING_OUT" | grep -qE 'TLS[[:space:]]*1\.3'; then
        echo -e "${RED}警告：$NEW_SNI 握手失败或不支持 TLS 1.3，REALITY 无法回落（客户端会报 EOF）。${PLAIN}"
        read -p "仍要强制使用？(y/n) [默认 n]: " FORCE_SNI
        if [[ "$FORCE_SNI" != "y" && "$FORCE_SNI" != "Y" ]]; then
            echo -e "${YELLOW}已取消，配置未改动。${PLAIN}"
            return 1
        fi
    else
        echo -e "${YELLOW}请确认上面输出中密钥交换为 X25519，否则 REALITY 会失败。${PLAIN}"
        read -p "确认继续？(y/n) [默认 y]: " OK_SNI
        OK_SNI=${OK_SNI:-y}
        if [[ "$OK_SNI" != "y" && "$OK_SNI" != "Y" ]]; then
            echo -e "${YELLOW}已取消，配置未改动。${PLAIN}"
            return 1
        fi
    fi

    TMP_JSON=$(mktemp)
    if ! jq --arg sni "$NEW_SNI" '.inbounds[0].streamSettings.realitySettings.serverNames[0] = $sni | .inbounds[0].streamSettings.realitySettings.dest = ($sni + ":443")' $CONFIG_FILE > $TMP_JSON; then
        echo -e "${RED}配置改写失败（jq 出错），已放弃。${PLAIN}"
        rm -f $TMP_JSON
        return 1
    fi
    mv $TMP_JSON $CONFIG_FILE

    TEST_OUT=$(/usr/local/bin/xray -test -c "$CONFIG_FILE" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}新配置校验失败：${PLAIN}"
        echo "$TEST_OUT"
        return 1
    fi

    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}Xray 重启失败，日志如下：${PLAIN}"
        journalctl -u xray -n 20 --no-pager
        diag_service
        return 1
    fi

    echo -e "${GREEN}伪装域名已更新为 $NEW_SNI，Xray 已重启。${PLAIN}"
    echo -e "${RED}重要：SNI 变更后客户端必须用下面的新链接重新导入，否则握手失败（EOF）。${PLAIN}"
    show_link
}

# 修改域名/SNI
modify_sni() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}未找到配置文件，请先安装！${PLAIN}"
        return
    fi
    local CUR_SNI NEW_SNI
    CUR_SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // ""' $CONFIG_FILE 2>/dev/null)
    echo -e "${BLUE}当前伪装域名：$CUR_SNI${PLAIN}"

    read -p "请输入新的伪装域名（留空=自动探测）: " NEW_SNI
    if [[ -z "$NEW_SNI" ]]; then
        auto_pick_sni || return
        NEW_SNI="$PICKED_SNI"
    fi
    apply_sni "$NEW_SNI"
}

# 自动探测伪装域名（只探测，可选应用到当前节点）
scan_sni_menu() {
    if ! auto_pick_sni; then
        return
    fi
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${YELLOW}尚未部署，可在安装时（菜单 1）直接回车使用自动探测。${PLAIN}"
        return
    fi
    local APPLY
    read -p "是否将本机伪装域名改为 $PICKED_SNI？(y/n) [默认 y]: " APPLY
    APPLY=${APPLY:-y}
    if [[ "$APPLY" == "y" || "$APPLY" == "Y" ]]; then
        apply_sni "$PICKED_SNI"
    else
        echo -e "${YELLOW}未改动配置，仅展示探测结果。${PLAIN}"
    fi
}

# 修改 UUID
modify_uuid() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}未找到配置文件，请先安装！${PLAIN}"
        return
    fi
    read -p "请输入新的 UUID (留空自动生成): " NEW_UUID
    [[ -z "$NEW_UUID" ]] && NEW_UUID=$(/usr/local/bin/xray uuid)

    TMP_JSON=$(mktemp)
    jq --arg uuid "$NEW_UUID" '.inbounds[0].settings.clients[0].id = $uuid' $CONFIG_FILE > $TMP_JSON
    mv $TMP_JSON $CONFIG_FILE

    systemctl restart xray
    echo -e "${GREEN}UUID 已更新为: $NEW_UUID，Xray 已重启。${PLAIN}"
    show_link
}

# 重装 Xray 后官方脚本会把 service 覆盖为 User=nobody，
# 特权端口(<1024)下若无 CAP_NET_BIND_SERVICE 将无法启动，这里自动修正为 root
ensure_service_permission() {
    local SVC PORT
    SVC=$(systemctl show -p FragmentPath xray 2>/dev/null | cut -d= -f2)
    [[ -z "$SVC" || ! -f "$SVC" ]] && SVC="/etc/systemd/system/xray.service"
    [[ -f "$SVC" ]] || return 0

    PORT=$(jq -r '.inbounds[0].port // empty' $CONFIG_FILE 2>/dev/null)
    [[ -n "$PORT" && "$PORT" -lt 1024 ]] || return 0

    if grep -qE '^User=(nobody|xray|www-data)' "$SVC" 2>/dev/null && \
       ! grep -qE '^AmbientCapabilities=.*CAP_NET_BIND_SERVICE' "$SVC" 2>/dev/null; then
        echo -e "${YELLOW}检测到 service 以非 root 用户运行且无 CAP_NET_BIND_SERVICE，"
        echo -e "端口 $PORT 为特权端口无法绑定，已自动改为 root 运行。${PLAIN}"
        sed -i 's/^User=.*/User=root/' "$SVC"
        systemctl daemon-reload
    fi
}

# 启动失败时的定向诊断（特权端口 / 运行用户 / 端口占用 / 残留进程）
diag_service() {
    echo -e "${YELLOW}>>> 启动失败定向诊断：${PLAIN}"

    local SVC PORT
    SVC=$(systemctl show -p FragmentPath xray 2>/dev/null | cut -d= -f2)
    [[ -z "$SVC" || ! -f "$SVC" ]] && SVC="/etc/systemd/system/xray.service"

    if [[ -f "$SVC" ]]; then
        echo -e "${BLUE}--- service 文件：$SVC${PLAIN}"
        grep -E '^(User|Group|CapabilityBoundingSet|AmbientCapabilities|NoNewPrivileges|ExecStart)' "$SVC" 2>/dev/null
    fi

    echo -e "${BLUE}--- systemd 版本：$(systemctl --version 2>/dev/null | head -1)${PLAIN}"

    PORT=$(jq -r '.inbounds[0].port // empty' $CONFIG_FILE 2>/dev/null)
    if [[ -n "$PORT" && "$PORT" -lt 1024 ]]; then
        echo -e "${RED}端口 $PORT 是特权端口（<1024）。${PLAIN}"
        if grep -qE '^User=(nobody|xray|www-data)' "$SVC" 2>/dev/null; then
            echo -e "${RED}service 以非 root 用户运行，若缺少 AmbientCapabilities=CAP_NET_BIND_SERVICE"
            echo -e "（或 systemd < 229 不支持该特性），Xray 会因无法绑定端口而启动失败（exit 23）。${PLAIN}"
            echo -e "${YELLOW}处理：把 User 改成 root，或改用 1024 以上端口。${PLAIN}"
        fi
    fi

    echo -e "${BLUE}--- 端口占用：${PLAIN}"
    ss -tlnp "sport = :${PORT}" 2>/dev/null || echo "(无)"
    echo -e "${BLUE}--- 残留 xray 进程：${PLAIN}"
    ps -o pid,user,cmd -C xray 2>/dev/null | tail -n +2 || echo "(无)"
}

# 检查服务状态
check_status() {
    echo -e "\n${BLUE}>>> Xray 服务运行状态：${PLAIN}"
    systemctl status xray --no-pager
    echo -e "\n${BLUE}>>> 查看最近 10 条日志：${PLAIN}"
    journalctl -u xray -n 10 --no-pager

    if ! systemctl is-active --quiet xray; then
        diag_service
    fi
}

# 重新生成 REALITY 密钥对（修复 privateKey 为空 / 密钥泄露）
regen_keys() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}未找到配置文件，请先安装！${PLAIN}"
        return
    fi
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}缺少 jq，请先安装：apt install -y jq${PLAIN}"
        return
    fi

    echo -e "${GREEN}>>> 正在生成新的 REALITY 密钥对...${PLAIN}"
    if ! gen_reality_keys; then
        echo -e "${RED}密钥生成失败，配置未改动。${PLAIN}"
        return 1
    fi

    TMP_JSON=$(mktemp)
    jq --arg pri "$PRIKEY" '.inbounds[0].streamSettings.realitySettings.privateKey = $pri' $CONFIG_FILE > $TMP_JSON
    mv $TMP_JSON $CONFIG_FILE

    cat << ENVEOF > $INFO_FILE
PUBKEY="$PUBKEY"
ENVEOF

    echo -e "${GREEN}已写入私钥：${PRIKEY:0:8}...（长度 ${#PRIKEY}），公钥：${PUBKEY:0:8}...${PLAIN}"

    TEST_OUT=$(/usr/local/bin/xray -test -c "$CONFIG_FILE" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Xray 配置校验失败：${PLAIN}"
        echo "$TEST_OUT"
        return 1
    fi

    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}密钥已更新，Xray 重启成功！${PLAIN}"
        show_link
    else
        echo -e "${RED}Xray 启动失败，日志如下：${PLAIN}"
        journalctl -u xray -n 20 --no-pager
        diag_service
    fi
}

# 交互式主菜单
main_menu() {
    # 菜单依赖交互输入，非 tty 环境（如 curl | bash）直接进入会死循环
    if [[ ! -t 0 ]]; then
        echo -e "${RED}当前不是交互式终端，无法使用菜单。${PLAIN}"
        echo -e "用法：$0 [install|update]"
        exit 1
    fi

    while true; do
        clear
        echo -e "${GREEN}==============================================${PLAIN}"
        echo -e "${GREEN}          VLESS-XHTTPS-REALITY 管理脚本       ${PLAIN}"
        echo -e "${GREEN}==============================================${PLAIN}"
        echo -e " 1. 一键部署 / 重置 XHTTPS 服务器"
        echo -e " 2. 查看节点一键导入链接 & 二维码"
        echo -e " 3. 修改伪装域名 (SNI)"
        echo -e " 4. 修改 UUID"
        echo -e " 5. 检查 Xray 运行状态与日志"
        echo -e " 6. 重启 Xray 服务"
        echo -e " 7. 重新生成 REALITY 密钥对（修复空私钥）"
        echo -e " 8. 更新脚本到最新版（从 Git 拉取）"
        echo -e " 9. 自动探测可用的伪装域名（SNI）"
        echo -e " 0. 退出脚本"
        echo -e "${GREEN}==============================================${PLAIN}"
        read -p "请输入数字选择功能 [0-9]: " choice

        case "$choice" in
            1) install_xhttp ;;
            2) show_link ;;
            3) modify_sni ;;
            4) modify_uuid ;;
            5) check_status ;;
            6) systemctl restart xray && echo -e "${GREEN}Xray 服务已重启！${PLAIN}" ;;
            7) regen_keys ;;
            8) self_update ;;
            9) scan_sni_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac

        echo ""
        read -p "按回车返回主菜单..." _
    done
}

# 启动入口：支持 install / update 子命令，无参数则进入菜单
case "${1:-}" in
    install|--install|-i) self_install ;;
    update|--update|-u)   self_update ;;
    "")                   main_menu ;;
    *)
        echo -e "用法：$(basename "$0") [install|update]"
        echo -e "  install  安装为全局命令 $INSTALL_PATH"
        echo -e "  update   更新脚本到最新版本"
        echo -e "  无参数   进入交互式管理菜单"
        exit 1
        ;;
esac