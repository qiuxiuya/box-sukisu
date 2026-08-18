#!/system/bin/sh

(
    until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do
        sleep 10
    done

    moddir="/data/adb/modules/box-sukisu"

    if [ -f "${moddir}/disable" ]; then
        exit 0
    fi

    if [ -f "${moddir}/service.sh" ]; then
        "${moddir}/service.sh" start
    else
        echo "未找到文件 '${moddir}/service.sh'"
    fi
)&
