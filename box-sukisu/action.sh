#!/system/bin/sh
MODDIR="${0%/*}"

SERVICE_SH="$MODDIR/service.sh"
MODULE_PROP="$MODDIR/module.prop"

getStatus() {
  status=$("$SERVICE_SH" status)
  if [ "$status" = "running" ]; then
    echo "running"
  else
    echo "stopped"
  fi
}

updateDescription() {
  statusText=$1
  desc="box-sukisu $statusText"
  desc=$(echo "$desc" | cut -c1-50)
  sed -i "s/^description=.*/description=$desc/" "$MODULE_PROP"
}

currentStatus=$(getStatus)
if [ "$currentStatus" = "running" ]; then
  "$SERVICE_SH" stop
  updateDescription "已停止 | 未在运行"
else
  "$SERVICE_SH" start
  updateDescription "已启动 | 后台守护运行中"
fi
