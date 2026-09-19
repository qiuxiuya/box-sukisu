#!/system/bin/sh
MODDIR="${0%/*}"

. "/data/adb/box/settings.ini"

BIN_NAME="$bin_name"

BOX_DIR="/data/adb/box"
RUN_DIR="$BOX_DIR/run"
BIN_DIR="$BOX_DIR/bin"
BIN_PATH="$BIN_DIR/$BIN_NAME"
DATA_DIR="$BOX_DIR/$BIN_NAME"
LOG_FILE="$RUN_DIR/core.log"
PID_FILE="$RUN_DIR/core.pid"
IPV6_STATE_FILE="$RUN_DIR/ipv6_state.save"
HS_LOG_FILE="$RUN_DIR/hotspot.log"
# 热点路由后台任务守卫：stopCore 先删除守卫文件，后台任务检测到即中止，避免清理后残留规则
HS_GUARD_FILE="$RUN_DIR/hotspot.enable"
HS_BG_PID_FILE="$RUN_DIR/hotspot.pid"

hotspotEnabled() {
  [ "$hotspot" != "false" ]
}

HS_MARK="50331648/50331648"
HS_TABLE="2025"
HS_PREF="99"
HS_CHAIN_FWD="BOX_HS_FWD"
HS_CHAIN_PRE="BOX_HS_PRE"

HS_BYPASS_MARK="67108864/67108864"
HS_BYPASS_TABLE="2026"
HS_BYPASS_PREF="98"
HS_CHAIN_BYPASS="BOX_HS_BYPASS"

detectWanIface() {
  ip -4 route show default 2>/dev/null | busybox awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detectWanIface6() {
  ip -6 route show default 2>/dev/null | busybox awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | head -n 1
}
HS_INTRANET="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32"
HS_INTRANET6="::1/128 fc00::/7 fe80::/10 ff00::/8 64:ff9b::/96"

hs_log() {
  mkdir -p "$RUN_DIR" >/dev/null 2>&1
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$HS_LOG_FILE" 2>/dev/null
}

isRunning() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      exe_link=$(readlink "/proc/$pid/exe" 2>/dev/null)
      [ "$exe_link" = "$BIN_PATH" ] && return 0
      cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
      case "$cmdline" in
        *"$BIN_PATH"*) return 0;;
      esac
    fi
  fi
  return 1
}

detectTunDevice() {
  dev=""
  if [ "$BIN_NAME" = "sing-box" ] && [ -f "$DATA_DIR/config.json" ]; then
    dev=$(grep -oE '"interface_name"[[:space:]]*:[[:space:]]*"[^"]+"' "$DATA_DIR/config.json" 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
    [ -z "$dev" ] && dev="tun0"
  elif [ -f "$DATA_DIR/config.yaml" ]; then
    dev=$(awk '/^ *tun:/{f=1;next} f && /^[^ ]/{f=0} f && /^[[:space:]]+device:/{print $2; exit}' "$DATA_DIR/config.yaml" 2>/dev/null | tr -d '"' | tr -d "'")
    [ -z "$dev" ] && dev="meta"
  fi
  echo "$dev"
}

waitForTunDevice() {
  _dev="$1"
  _i=0
  while [ "$_i" -lt 20 ]; do
    # 等待期间响应停止信号，避免停止核心后后台任务继续写规则
    [ -f "$HS_GUARD_FILE" ] || return 2
    ip link show "$_dev" >/dev/null 2>&1 && return 0
    _i=$((_i + 1))
    sleep 1
  done
  return 1
}

applyHotspotBypass() {
  hs_log "hotspot=false：开始下发热点绕过规则"

  if [ ! -d /proc/sys/net/ipv4 ]; then
    hs_log "未找到 IPv4 支持，跳过热点绕过"
    return 1
  fi

  wan=$(detectWanIface)
  if [ -z "$wan" ]; then
    hs_log "未检测到默认出口接口，跳过热点绕过"
    return 1
  fi

  # 借鉴 box-1.2.8：只将 ip_forward 置 1，不保存旧值。
  # Android netd 仅在热点开/关事件时设置该值，恢复旧值(可能为0)会切断热点转发。
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

  iptables -t mangle -N "$HS_CHAIN_BYPASS" 2>/dev/null
  iptables -t mangle -F "$HS_CHAIN_BYPASS" 2>/dev/null
  iptables -t mangle -A "$HS_CHAIN_BYPASS" -o "$wan" -j RETURN
  iptables -t mangle -A "$HS_CHAIN_BYPASS" -j MARK --set-xmark $HS_BYPASS_MARK
  iptables -t mangle -C PREROUTING -j "$HS_CHAIN_BYPASS" 2>/dev/null || iptables -t mangle -I PREROUTING -j "$HS_CHAIN_BYPASS"

  ip rule del fwmark $HS_BYPASS_MARK table $HS_BYPASS_TABLE pref $HS_BYPASS_PREF 2>/dev/null
  ip rule add fwmark $HS_BYPASS_MARK table $HS_BYPASS_TABLE pref $HS_BYPASS_PREF 2>/dev/null || true
  ip route replace default dev "$wan" table $HS_BYPASS_TABLE 2>/dev/null || true

  hs_log "IPv4 热点流量已通过 ${wan} 直接出站（绕过 TUN）"

  if [ "$ipv6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
    wan6=$(detectWanIface6)
    if [ -n "$wan6" ]; then
      ip6tables -N "$HS_CHAIN_FWD" 2>/dev/null
      ip6tables -F "$HS_CHAIN_FWD" 2>/dev/null
      ip6tables -C FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null || ip6tables -I FORWARD -j "$HS_CHAIN_FWD"

      ip6tables -t mangle -N "$HS_CHAIN_BYPASS" 2>/dev/null
      ip6tables -t mangle -F "$HS_CHAIN_BYPASS" 2>/dev/null
      ip6tables -t mangle -A "$HS_CHAIN_BYPASS" -o "$wan6" -j RETURN
      ip6tables -t mangle -A "$HS_CHAIN_BYPASS" -j MARK --set-xmark $HS_BYPASS_MARK
      ip6tables -t mangle -C PREROUTING -j "$HS_CHAIN_BYPASS" 2>/dev/null || ip6tables -t mangle -I PREROUTING -j "$HS_CHAIN_BYPASS"

      ip -6 rule del fwmark $HS_BYPASS_MARK table $HS_BYPASS_TABLE pref $HS_BYPASS_PREF 2>/dev/null
      ip -6 rule add fwmark $HS_BYPASS_MARK table $HS_BYPASS_TABLE pref $HS_BYPASS_PREF 2>/dev/null || true
      ip -6 route replace default dev "$wan6" table $HS_BYPASS_TABLE 2>/dev/null || true

      hs_log "IPv6 热点流量已通过 ${wan6} 直接出站（绕过 TUN）"
    else
      hs_log "未检测到 IPv6 默认出口，跳过 IPv6 绕过规则"
    fi
  fi
}

applyHotspotRouting() {
  : > "$HS_LOG_FILE" 2>/dev/null

  if ! hotspotEnabled; then
    applyHotspotBypass
    return $?
  fi

  hs_dev=$(detectTunDevice)
  hs_log "从配置读取的 TUN 设备名: ${hs_dev}"
  waitForTunDevice "$hs_dev"
  _wait_rv=$?
  if [ "$_wait_rv" = "2" ]; then
    hs_log "检测到停止信号，中止热点路由下发"
    return 1
  fi
  if [ "$_wait_rv" != "0" ]; then
    hs_log "未检测到 TUN 设备 ${hs_dev}，跳过热点路由"
    return 1
  fi

  if ! isRunning; then
    hs_log "核心未在运行，跳过热点路由"
    return 1
  fi

  # 写规则前最后确认未被停止，消除与 stopCore 的竞态
  if [ ! -f "$HS_GUARD_FILE" ]; then
    hs_log "检测到停止信号，跳过热点路由"
    return 1
  fi

  # 借鉴 box-1.2.8：只将 ip_forward 置 1，不保存旧值。
  if [ -d /proc/sys/net/ipv4 ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  fi

  iptables -N "$HS_CHAIN_FWD" 2>/dev/null
  iptables -F "$HS_CHAIN_FWD" 2>/dev/null
  iptables -A "$HS_CHAIN_FWD" -i "$hs_dev" -j ACCEPT
  iptables -A "$HS_CHAIN_FWD" -o "$hs_dev" -j ACCEPT
  iptables -C FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null || iptables -I FORWARD -j "$HS_CHAIN_FWD"

  iptables -t mangle -N "$HS_CHAIN_PRE" 2>/dev/null
  iptables -t mangle -F "$HS_CHAIN_PRE" 2>/dev/null
  iptables -t mangle -A "$HS_CHAIN_PRE" -i "$hs_dev" -j RETURN
  for subnet in $HS_INTRANET; do
    iptables -t mangle -A "$HS_CHAIN_PRE" -d "$subnet" -j RETURN
  done
  iptables -t mangle -A "$HS_CHAIN_PRE" -p udp --dport 53 -j MARK --set-xmark $HS_MARK
  iptables -t mangle -A "$HS_CHAIN_PRE" -j MARK --set-xmark $HS_MARK
  iptables -t mangle -C PREROUTING -j "$HS_CHAIN_PRE" 2>/dev/null || iptables -t mangle -I PREROUTING -j "$HS_CHAIN_PRE"

  ip rule del fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null
  ip rule add fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null || true
  ip route replace default dev "$hs_dev" table $HS_TABLE 2>/dev/null || true

  hs_log "IPv4 客户端流量已通过 ${hs_dev} 导入代理"

  if [ "$ipv6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
    ip6tables -N "$HS_CHAIN_FWD" 2>/dev/null
    ip6tables -F "$HS_CHAIN_FWD" 2>/dev/null
    ip6tables -A "$HS_CHAIN_FWD" -i "$hs_dev" -j ACCEPT
    ip6tables -A "$HS_CHAIN_FWD" -o "$hs_dev" -j ACCEPT
    ip6tables -C FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null || ip6tables -I FORWARD -j "$HS_CHAIN_FWD"

    ip6tables -t mangle -N "$HS_CHAIN_PRE" 2>/dev/null
    ip6tables -t mangle -F "$HS_CHAIN_PRE" 2>/dev/null
    ip6tables -t mangle -A "$HS_CHAIN_PRE" -i "$hs_dev" -j RETURN
    for subnet6 in $HS_INTRANET6; do
      ip6tables -t mangle -A "$HS_CHAIN_PRE" -d "$subnet6" -j RETURN
    done
    ip6tables -t mangle -A "$HS_CHAIN_PRE" -p udp --dport 53 -j MARK --set-xmark $HS_MARK
    ip6tables -t mangle -A "$HS_CHAIN_PRE" -j MARK --set-xmark $HS_MARK
    ip6tables -t mangle -C PREROUTING -j "$HS_CHAIN_PRE" 2>/dev/null || ip6tables -t mangle -I PREROUTING -j "$HS_CHAIN_PRE"

    ip -6 rule del fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null
    ip -6 rule add fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null || true
    ip -6 route replace default dev "$hs_dev" table $HS_TABLE 2>/dev/null || true

    hs_log "IPv6 客户端流量已通过 ${hs_dev} 导入代理"
  fi
}

removeHotspotRouting() {
  iptables -D FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null
  iptables -F "$HS_CHAIN_FWD" 2>/dev/null
  iptables -X "$HS_CHAIN_FWD" 2>/dev/null
  iptables -t mangle -D PREROUTING -j "$HS_CHAIN_PRE" 2>/dev/null
  iptables -t mangle -F "$HS_CHAIN_PRE" 2>/dev/null
  iptables -t mangle -X "$HS_CHAIN_PRE" 2>/dev/null

  ip rule del fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null
  ip rule del fwmark $HS_BYPASS_MARK table $HS_BYPASS_TABLE pref $HS_BYPASS_PREF 2>/dev/null
  ip route flush table $HS_TABLE 2>/dev/null
  ip route flush table $HS_BYPASS_TABLE 2>/dev/null

  iptables -t mangle -D PREROUTING -j "$HS_CHAIN_BYPASS" 2>/dev/null
  iptables -t mangle -F "$HS_CHAIN_BYPASS" 2>/dev/null
  iptables -t mangle -X "$HS_CHAIN_BYPASS" 2>/dev/null

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -D FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null
    ip6tables -F "$HS_CHAIN_FWD" 2>/dev/null
    ip6tables -X "$HS_CHAIN_FWD" 2>/dev/null
    ip6tables -t mangle -D PREROUTING -j "$HS_CHAIN_PRE" 2>/dev/null
    ip6tables -t mangle -F "$HS_CHAIN_PRE" 2>/dev/null
    ip6tables -t mangle -X "$HS_CHAIN_PRE" 2>/dev/null

    ip6tables -t mangle -D PREROUTING -j "$HS_CHAIN_BYPASS" 2>/dev/null
    ip6tables -t mangle -F "$HS_CHAIN_BYPASS" 2>/dev/null
    ip6tables -t mangle -X "$HS_CHAIN_BYPASS" 2>/dev/null

    ip -6 rule del fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null
    ip -6 rule del fwmark $HS_BYPASS_MARK table $HS_BYPASS_TABLE pref $HS_BYPASS_PREF 2>/dev/null
    ip -6 route flush table $HS_TABLE 2>/dev/null
    ip -6 route flush table $HS_BYPASS_TABLE 2>/dev/null
  fi

  # 借鉴 box-1.2.8：不恢复 ip_forward（box.iptables 的 forward() 清理时同样不回退）。
  # Android netd 仅在热点开/关事件时设置该值；若核心启动早于热点开启，保存值可能为 0，
  # 停止核心时恢复 0 会导致热点转发瘫痪、客户端全部断网。
  rm -f "$RUN_DIR/ip_forward.save"
}

rotateLogs() {
  MAX_LOG_SIZE=1048576
  LOG_BAK="$LOG_FILE.1"

  if [ -f "$LOG_FILE" ]; then
    logSize=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE")
    if [ "$logSize" -ge "$MAX_LOG_SIZE" ]; then
      mv "$LOG_FILE" "$LOG_BAK"
      touch "$LOG_FILE"
      echo "[日志轮换] core.log 已轮换为 core.log.1" >> "$LOG_FILE"
    fi
  fi
}

applyIpv6Settings() {
  [ -d /proc/sys/net/ipv6 ] || return 0

  local target_value="1"
  [ "$ipv6" = "true" ] && target_value="0"

  printf '%s\n' "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" > "$IPV6_STATE_FILE"

  for iface in all default; do
    echo "$target_value" > "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" 2>/dev/null || true
  done

  [ "$ipv6" = "true" ] && echo "IPv6 已启用" || echo "IPv6 已禁用"
}

restoreIpv6Settings() {
  [ -f "$IPV6_STATE_FILE" ] || return 0
  [ -d /proc/sys/net/ipv6 ] || return 0

  local old_value
  old_value=$(cat "$IPV6_STATE_FILE")
  for iface in all default; do
    echo "$old_value" > "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" 2>/dev/null || true
  done
  rm -f "$IPV6_STATE_FILE"
}

applyQuicBlock() {
  [ "$quic" = "true" ] && return 0

  if command -v iptables >/dev/null 2>&1; then
    iptables -C OUTPUT -p udp -m multiport --dport 80,443 -j REJECT >/dev/null 2>&1 || \
      iptables -A OUTPUT -p udp -m multiport --dport 80,443 -j REJECT
  fi

  if [ "$ipv6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C OUTPUT -p udp -m multiport --dport 80,443 -j REJECT >/dev/null 2>&1 || \
      ip6tables -A OUTPUT -p udp -m multiport --dport 80,443 -j REJECT
  fi

  echo "QUIC 已拦截"
}

cleanupQuicBlock() {
  if command -v iptables >/dev/null 2>&1; then
    iptables -D OUTPUT -p udp -m multiport --dport 80,443 -j REJECT >/dev/null 2>&1 || true
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -D OUTPUT -p udp -m multiport --dport 80,443 -j REJECT >/dev/null 2>&1 || true
  fi
}

startCore() {
  if [ -f "$PID_FILE" ]; then
    oldPid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$oldPid" ] && kill -0 "$oldPid" 2>/dev/null; then
      kill "$oldPid" 2>/dev/null
      echo "旧核心已停止 (PID: $oldPid)"
    fi
    rm -f "$PID_FILE"
  fi

  if isRunning; then
    echo "$BIN_NAME 已在运行 (PID: $(cat $PID_FILE))"
    return 0
  fi

  if [ ! -x "$BIN_PATH" ]; then
    echo "[错误] 未找到可执行的 $BIN_NAME 二进制：$BIN_PATH"
    return 1
  fi

  if [ "$BIN_NAME" = "sing-box" ] && [ ! -f "$DATA_DIR/config.json" ]; then
    echo "[错误] 未找到 sing-box 配置文件：$DATA_DIR/config.json"
    return 1
  fi

  mkdir -p "$RUN_DIR"
  rotateLogs

  case "$BIN_NAME" in
    sing-box)
      nohup "$BIN_PATH" run -c "$DATA_DIR/config.json" -D "$DATA_DIR" >> "$LOG_FILE" 2>&1 &
      ;;
    mihomo|*)
      nohup "$BIN_PATH" -d "$DATA_DIR" >> "$LOG_FILE" 2>&1 &
      ;;
  esac

  echo $! > "$PID_FILE"
  echo "$BIN_NAME 已启动 (PID: $(cat $PID_FILE))"

  applyIpv6Settings
  applyQuicBlock

  # 先立守卫再异步下发热点路由，并记录后台任务 PID 供 stopCore 等待
  : > "$HS_GUARD_FILE"
  applyHotspotRouting &
  echo $! > "$HS_BG_PID_FILE" 2>/dev/null
}

# 等待热点路由后台任务退出（跨进程通过 PID 文件），避免清理与写入竞态
waitHotspotBgExit() {
  [ -f "$HS_BG_PID_FILE" ] || return 0
  _bg_pid=$(cat "$HS_BG_PID_FILE" 2>/dev/null)
  [ -n "$_bg_pid" ] || { rm -f "$HS_BG_PID_FILE"; return 0; }
  _i=0
  while [ "$_i" -lt 25 ]; do
    kill -0 "$_bg_pid" 2>/dev/null || break
    sleep 0.2
    _i=$((_i + 1))
  done
  rm -f "$HS_BG_PID_FILE"
}

stopCore() {
  # 1) 先撤销守卫并等待后台热点任务退出，防止规则被清理后又被写入
  rm -f "$HS_GUARD_FILE"
  waitHotspotBgExit

  # 2) 借鉴 box-1.2.8 停止流程（先 box.iptables disable 再停核心）：
  #    先清理热点转发/标记规则，恢复客户端直连，避免"TUN 已消失但规则仍在"的断网空窗
  removeHotspotRouting

  # 3) 停止核心：优雅退出超时后强杀，确保 TUN 与核心 auto-route 被可靠回收
  if isRunning; then
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    _i=0
    while [ "$_i" -lt 10 ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
      _i=$((_i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
      echo "$BIN_NAME 未响应，已强制结束 (PID: $pid)"
    fi
    rm -f "$PID_FILE"
    echo "$BIN_NAME 已停止"
  else
    echo "$BIN_NAME 未在运行"
  fi

  # 4) 兜底再次清理热点规则与系统设置
  removeHotspotRouting
  cleanupQuicBlock
  restoreIpv6Settings
}

case "$1" in
  start)
    startCore
    ;;
  stop)
    stopCore
    ;;
  status)
    if isRunning; then
      echo "running"
    else
      echo "stopped"
    fi
    ;;
  *)
    echo "用法: $0 {start|stop|status}"
    ;;
esac
