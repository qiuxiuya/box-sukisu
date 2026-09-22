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
HS_LOG_FILE="$RUN_DIR/hotspot.log"
HS_GUARD_FILE="$RUN_DIR/hotspot.enable"
HS_BG_PID_FILE="$RUN_DIR/hotspot.pid"
IPV6_UNREACHABLE_PREF=10000

HS_MARK="50331648/50331648"
HS_TABLE="2025"
HS_PREF="99"
HS_CHAIN_FWD="BOX_HS_FWD"
HS_CHAIN_PRE="BOX_HS_PRE"
HS_BYPASS_MARK="67108864/67108864"
HS_BYPASS_TABLE="2026"
HS_BYPASS_PREF="98"
HS_CHAIN_BYPASS="BOX_HS_BYPASS"
HS_INTRANET="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32"
HS_INTRANET6="::1/128 fc00::/7 fe80::/10 ff00::/8 64:ff9b::/96"

hotspotEnabled() { [ "$hotspot" != "false" ]; }

detectWanIface() {
  ip -4 route show default 2>/dev/null | busybox awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
detectWanIface6() {
  ip -6 route show default 2>/dev/null | busybox awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | head -n 1
}

hs_log() {
  mkdir -p "$RUN_DIR" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$HS_LOG_FILE" 2>/dev/null
}

isRunning() {
  [ -f "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  exe_link=$(readlink "/proc/$pid/exe" 2>/dev/null)
  [ "$exe_link" = "$BIN_PATH" ] && return 0
  cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
  case "$cmdline" in *"$BIN_PATH"*) return 0;; esac
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
    [ -f "$HS_GUARD_FILE" ] || return 2
    ip link show "$_dev" >/dev/null 2>&1 && return 0
    _i=$((_i + 1))
    sleep 1
  done
  return 1
}

setup_hotspot_bypass() {
  local ipt="$1" ipcmd="$2" wan="$3" mark="$4" table="$5" pref="$6" chain="$7"
  $ipt -t mangle -N "$chain" 2>/dev/null
  $ipt -t mangle -F "$chain" 2>/dev/null
  $ipt -t mangle -A "$chain" -o "$wan" -j RETURN
  $ipt -t mangle -A "$chain" -j MARK --set-xmark "$mark"
  $ipt -t mangle -C PREROUTING -j "$chain" 2>/dev/null || $ipt -t mangle -I PREROUTING -j "$chain"
  $ipcmd rule del fwmark "$mark" table "$table" pref "$pref" 2>/dev/null
  $ipcmd rule add fwmark "$mark" table "$table" pref "$pref" 2>/dev/null || true
  $ipcmd route replace default dev "$wan" table "$table" 2>/dev/null || true
}

applyHotspotBypass() {
  hs_log "hotspot=false：开始下发热点绕过规则"
  [ -d /proc/sys/net/ipv4 ] || { hs_log "未找到 IPv4 支持，跳过热点绕过"; return 1; }
  wan=$(detectWanIface)
  [ -z "$wan" ] && { hs_log "未检测到默认出口接口，跳过热点绕过"; return 1; }
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

  setup_hotspot_bypass iptables ip "$wan" "$HS_BYPASS_MARK" "$HS_BYPASS_TABLE" "$HS_BYPASS_PREF" "$HS_CHAIN_BYPASS"
  hs_log "IPv4 热点流量已通过 ${wan} 直接出站（绕过 TUN）"

  if [ "$ipv6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
    wan6=$(detectWanIface6)
    if [ -n "$wan6" ]; then
      ip6tables -N "$HS_CHAIN_FWD" 2>/dev/null
      ip6tables -F "$HS_CHAIN_FWD" 2>/dev/null
      ip6tables -C FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null || ip6tables -I FORWARD -j "$HS_CHAIN_FWD"
      setup_hotspot_bypass ip6tables "ip -6" "$wan6" "$HS_BYPASS_MARK" "$HS_BYPASS_TABLE" "$HS_BYPASS_PREF" "$HS_CHAIN_BYPASS"
      hs_log "IPv6 热点流量已通过 ${wan6} 直接出站（绕过 TUN）"
    else
      hs_log "未检测到 IPv6 默认出口，跳过 IPv6 绕过规则"
    fi
  fi
}

setup_hotspot_proxy() {
  local ipt="$1" ipcmd="$2" dev="$3" intranet="$4"
  $ipt -N "$HS_CHAIN_FWD" 2>/dev/null
  $ipt -F "$HS_CHAIN_FWD" 2>/dev/null
  $ipt -A "$HS_CHAIN_FWD" -i "$dev" -j ACCEPT
  $ipt -A "$HS_CHAIN_FWD" -o "$dev" -j ACCEPT
  $ipt -C FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null || $ipt -I FORWARD -j "$HS_CHAIN_FWD"

  $ipt -t mangle -N "$HS_CHAIN_PRE" 2>/dev/null
  $ipt -t mangle -F "$HS_CHAIN_PRE" 2>/dev/null
  $ipt -t mangle -A "$HS_CHAIN_PRE" -i "$dev" -j RETURN
  for subnet in $intranet; do
    $ipt -t mangle -A "$HS_CHAIN_PRE" -d "$subnet" -j RETURN
  done
  $ipt -t mangle -A "$HS_CHAIN_PRE" -p udp --dport 53 -j MARK --set-xmark $HS_MARK
  $ipt -t mangle -A "$HS_CHAIN_PRE" -j MARK --set-xmark $HS_MARK
  $ipt -t mangle -C PREROUTING -j "$HS_CHAIN_PRE" 2>/dev/null || $ipt -t mangle -I PREROUTING -j "$HS_CHAIN_PRE"

  $ipcmd rule del fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null
  $ipcmd rule add fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null || true
  $ipcmd route replace default dev "$dev" table $HS_TABLE 2>/dev/null || true
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
  if [ ! -f "$HS_GUARD_FILE" ]; then
    hs_log "检测到停止信号，跳过热点路由"
    return 1
  fi

  if [ -d /proc/sys/net/ipv4 ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  fi

  setup_hotspot_proxy iptables ip "$hs_dev" "$HS_INTRANET"
  hs_log "IPv4 客户端流量已通过 ${hs_dev} 导入代理"

  if [ "$ipv6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
    setup_hotspot_proxy ip6tables "ip -6" "$hs_dev" "$HS_INTRANET6"
    hs_log "IPv6 客户端流量已通过 ${hs_dev} 导入代理"
  fi
}

cleanup_hotspot() {
  local ipt="$1" ipcmd="$2"
  $ipt -D FORWARD -j "$HS_CHAIN_FWD" 2>/dev/null
  $ipt -F "$HS_CHAIN_FWD" 2>/dev/null
  $ipt -X "$HS_CHAIN_FWD" 2>/dev/null
  $ipt -t mangle -D PREROUTING -j "$HS_CHAIN_PRE" 2>/dev/null
  $ipt -t mangle -F "$HS_CHAIN_PRE" 2>/dev/null
  $ipt -t mangle -X "$HS_CHAIN_PRE" 2>/dev/null
  $ipt -t mangle -D PREROUTING -j "$HS_CHAIN_BYPASS" 2>/dev/null
  $ipt -t mangle -F "$HS_CHAIN_BYPASS" 2>/dev/null
  $ipt -t mangle -X "$HS_CHAIN_BYPASS" 2>/dev/null

  $ipcmd rule del fwmark $HS_MARK table $HS_TABLE pref $HS_PREF 2>/dev/null
  $ipcmd rule del fwmark $HS_BYPASS_MARK table $HS_BYPASS_TABLE pref $HS_BYPASS_PREF 2>/dev/null
  $ipcmd route flush table $HS_TABLE 2>/dev/null
  $ipcmd route flush table $HS_BYPASS_TABLE 2>/dev/null
}

removeHotspotRouting() {
  cleanup_hotspot iptables ip
  if command -v ip6tables >/dev/null 2>&1; then
    cleanup_hotspot ip6tables "ip -6"
  fi
  rm -f "$RUN_DIR/ip_forward.save"
}

rotateLogs() {
  [ -f "$LOG_FILE" ] || return 0
  local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE")
  if [ "$size" -ge 1048576 ]; then
    mv "$LOG_FILE" "$LOG_FILE.1"
    touch "$LOG_FILE"
    echo "[日志轮换] core.log 已轮换为 core.log.1" >> "$LOG_FILE"
  fi
}

set_ipv6_conf_all() {
  local key="$1" value="$2" path
  for path in /proc/sys/net/ipv6/conf/*/"${key}"; do
    [ -e "${path}" ] || continue
    echo "${value}" > "${path}" 2>/dev/null || true
  done
}

ipv6_enable() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
  set_ipv6_conf_all disable_ipv6 0
  set_ipv6_conf_all autoconf 1
  set_ipv6_conf_all accept_ra 2
  set_ipv6_conf_all accept_ra_defrtr 1
  set_ipv6_conf_all accept_ra_pinfo 1
  ip -6 rule show pref "${IPV6_UNREACHABLE_PREF}" 2>/dev/null | grep -q "unreachable" && \
    ip -6 rule del unreachable pref "${IPV6_UNREACHABLE_PREF}" >/dev/null 2>&1 || true
}

disable_ipv6() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
  sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1
  set_ipv6_conf_all accept_ra 0
  set_ipv6_conf_all disable_ipv6 1
  ip -6 rule show pref "${IPV6_UNREACHABLE_PREF}" 2>/dev/null | grep -q "unreachable" || \
    ip -6 rule add unreachable pref "${IPV6_UNREACHABLE_PREF}"
}

applyIpv6Settings() {
  [ -d /proc/sys/net/ipv6 ] || return 0
  if [ "$ipv6" = "true" ]; then
    ipv6_enable
    echo "IPv6 已启用"
  else
    disable_ipv6
    echo "IPv6 已禁用"
  fi
}

restoreIpv6Settings() {
  [ -d /proc/sys/net/ipv6 ] || return 0
  ipv6_enable
  echo "IPv6 已恢复启用"
}

set_quic_block() {
  local action="$1" ipt
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    if [ "$action" = "add" ]; then
      $ipt -C OUTPUT -p udp -m multiport --dport 80,443 -j REJECT >/dev/null 2>&1 || \
        $ipt -A OUTPUT -p udp -m multiport --dport 80,443 -j REJECT
    else
      $ipt -D OUTPUT -p udp -m multiport --dport 80,443 -j REJECT >/dev/null 2>&1 || true
    fi
  done
}

applyQuicBlock() {
  [ "$quic" = "true" ] && return 0
  set_quic_block add
  echo "QUIC 已拦截"
}

cleanupQuicBlock() {
  set_quic_block del
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

  : > "$HS_GUARD_FILE"
  applyHotspotRouting &
  echo $! > "$HS_BG_PID_FILE" 2>/dev/null
}

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
  rm -f "$HS_GUARD_FILE"
  waitHotspotBgExit
  removeHotspotRouting

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

  removeHotspotRouting
  cleanupQuicBlock
  restoreIpv6Settings
}

case "$1" in
  start) startCore ;;
  stop) stopCore ;;
  status) isRunning && echo "running" || echo "stopped" ;;
  *) echo "用法: $0 {start|stop|status}" ;;
esac