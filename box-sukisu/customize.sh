#!/system/bin/sh

BOX_DIR="/data/adb/box"

mkdir -p "$BOX_DIR/bin"
mkdir -p "$BOX_DIR/mihomo"
mkdir -p "$BOX_DIR/sing-box"
mkdir -p "$BOX_DIR/run"

[ ! -f "$BOX_DIR/settings.ini" ] && cp "$MODPATH/settings.ini" "$BOX_DIR/settings.ini"

set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
