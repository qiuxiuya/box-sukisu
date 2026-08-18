#!/system/bin/sh

BOX_DIR="/data/adb/box"

service_dir="/data/adb/service.d"
if [ "$KSU" = "true" ] && [ "$KSU_VER_CODE" -lt 10683 ]; then
  service_dir="/data/adb/ksu/service.d"
fi

mkdir -p "$service_dir"

mkdir -p "$BOX_DIR/bin"
mkdir -p "$BOX_DIR/mihomo"
mkdir -p "$BOX_DIR/sing-box"
mkdir -p "$BOX_DIR/run"

[ ! -f "$BOX_DIR/settings.ini" ] && cp "$MODPATH/settings.ini" "$BOX_DIR/settings.ini"

cp -f "$MODPATH/box_service.sh" "$service_dir/box_service.sh"

set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$service_dir/box_service.sh" 0 0 0755
