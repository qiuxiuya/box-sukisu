#!/system/bin/sh

MODDIR="${0%/*}"
BOX_DIR="/data/adb/box"

SERVICE_SH="$MODDIR/service.sh"
[ -x "$SERVICE_SH" ] && "$SERVICE_SH" stop >/dev/null 2>&1 || true

rm -f "/data/adb/ksu/service.d/box_service.sh"
rm -f "/data/adb/service.d/box_service.sh"

rm -rf "$BOX_DIR"
