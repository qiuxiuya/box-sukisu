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
}

stopCore() {
  if isRunning; then
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    echo "$BIN_NAME 已停止"
  else
    echo "$BIN_NAME 未在运行"
  fi

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
