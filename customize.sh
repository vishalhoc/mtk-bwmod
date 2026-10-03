#!/system/bin/sh
# =============================================================================
# MTK Extreme Bandwidth Mod v1.0 — customize.sh
# Universal installer — all MediaTek devices
# =============================================================================

SKIPUNZIP=1

DEVICE=$(getprop ro.product.device)
MODEL=$(getprop ro.product.model)
BRAND=$(getprop ro.product.brand)
PLATFORM=$(getprop ro.board.platform)
VENDOR_PLATFORM=$(getprop ro.vendor.mediatek.platform)
SOC=$(getprop ro.soc.model 2>/dev/null)
HARDWARE=$(getprop ro.hardware)
ANDROID=$(getprop ro.build.version.release)
ARCH=$(getprop ro.product.cpu.abi)
CPUS=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( RAM_KB / 1024 / 1024 ))

ui_print ""
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "   MTK Extreme Bandwidth Mod v1.0"
ui_print "   Universal · Helio · Dimensity · MT"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print ""
ui_print "  Device   : $BRAND $MODEL"
ui_print "  Codename : $DEVICE"
ui_print "  Android  : $ANDROID  |  $ARCH"
ui_print "  Platform : ${PLATFORM:-unknown}"
ui_print "  SoC      : ${VENDOR_PLATFORM:-${SOC:-unknown}}"
ui_print "  RAM      : ${RAM_GB}GB  |  CPUs: $CPUS"
ui_print ""
ui_print "  Detecting MediaTek hardware..."

# 9-method MTK detection
IS_MTK=0
MTK_REASON=""
echo "$PLATFORM"        | grep -qi "^mt"       && IS_MTK=1 && MTK_REASON="ro.board.platform=$PLATFORM"
echo "$VENDOR_PLATFORM" | grep -qi "^mt"       && IS_MTK=1 && MTK_REASON="ro.vendor.mediatek.platform=$VENDOR_PLATFORM"
echo "$HARDWARE"        | grep -qi "^mt"       && IS_MTK=1 && MTK_REASON="ro.hardware=$HARDWARE"
echo "$SOC"             | grep -qi "^mt"       && IS_MTK=1 && MTK_REASON="ro.soc.model=$SOC"
echo "$SOC"             | grep -qi "dimensity" && IS_MTK=1 && MTK_REASON="Dimensity=$SOC"
[ -f /proc/mtk_battery_cmd ]                   && IS_MTK=1 && MTK_REASON="/proc/mtk_battery_cmd"
[ -d /sys/devices/platform/mediatek ]          && IS_MTK=1 && MTK_REASON="/sys/devices/platform/mediatek"
[ -f /sys/kernel/debug/mtk_btcvsd ]            && IS_MTK=1 && MTK_REASON="MTK BT CVSD node"
getprop | grep -q "\.mtk\." 2>/dev/null        && IS_MTK=1 && MTK_REASON="MTK props namespace"

if [ "$IS_MTK" != "1" ]; then
    ui_print ""
    ui_print "  ✗  Non-MediaTek device!"
    ui_print "     Platform : ${PLATFORM:-unknown}"
    ui_print "     SoC      : ${SOC:-unknown}"
    ui_print "     Hardware : ${HARDWARE:-unknown}"
    ui_print ""
    ui_print "  Module is MTK-only. Aborted."
    ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    abort
fi

ui_print "  ✓  MediaTek confirmed"
ui_print "     $MTK_REASON"
ui_print ""

unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

# Normalize any backslash filenames extracted by Windows zip tools
mkdir -p "$MODPATH/web/cgi-bin" "$MODPATH/system/etc/init" "$MODPATH/system/etc/sysctl.d" 2>/dev/null
for f in "$MODPATH"/*; do
    base=$(basename "$f")
    case "$base" in
        web\\index.html) mv "$f" "$MODPATH/web/index.html" 2>/dev/null ;;
        web\\cgi-bin\\api.sh) mv "$f" "$MODPATH/web/cgi-bin/api.sh" 2>/dev/null ;;
        portfolio\\index.html) mkdir -p "$MODPATH/portfolio"; mv "$f" "$MODPATH/portfolio/index.html" 2>/dev/null ;;
        system\\etc\\init\\mtk-bwmod.rc) mv "$f" "$MODPATH/system/etc/init/mtk-bwmod.rc" 2>/dev/null ;;
        system\\etc\\sysctl.d\\99-mtk-bwmod.conf) mv "$f" "$MODPATH/system/etc/sysctl.d/99-mtk-bwmod.conf" 2>/dev/null ;;
    esac
done

set_perm_recursive "$MODPATH" root root 0755 0644
set_perm "$MODPATH/service.sh" root root 0755
set_perm "$MODPATH/post-fs-data.sh" root root 0755
set_perm "$MODPATH/action.sh" root root 0755
set_perm_recursive "$MODPATH/web" root root 0755 0644
set_perm "$MODPATH/web/cgi-bin/api.sh" root root 0755
[ -f "$MODPATH/system/etc/init/mtk-bwmod.rc" ] && set_perm "$MODPATH/system/etc/init/mtk-bwmod.rc" root root 0644
[ -f "$MODPATH/system/etc/sysctl.d/99-mtk-bwmod.conf" ] && set_perm "$MODPATH/system/etc/sysctl.d/99-mtk-bwmod.conf" root root 0644

# Setup initial profile
[ ! -f /data/local/tmp/mtk_bwmod_profile ] && echo "performance" > /data/local/tmp/mtk_bwmod_profile

# Pre-deploy web UI
mkdir -p /data/local/mtk_bwmod/web/cgi-bin 2>/dev/null
cp -rf "$MODPATH/web/"* /data/local/mtk_bwmod/web/ 2>/dev/null
chmod -R 0755 /data/local/mtk_bwmod/web 2>/dev/null
chmod 0755 /data/local/mtk_bwmod/web/cgi-bin/api.sh 2>/dev/null

PROP_COUNT=$(grep -c "=" "$MODPATH/system.prop" 2>/dev/null || echo 0)
ui_print "  ✓  system.prop  ($PROP_COUNT props, 27 sections)"
ui_print "  ✓  post-fs-data (early kernel socket & net tuning)"
ui_print "  ✓  service.sh   (boot service & profile restore)"
ui_print "  ✓  web/         (Web Control Panel on port 8096)"
ui_print "  ✓  action.sh    (Action Button & Profile Switcher)"
ui_print ""
ui_print "  Control Panel:"
ui_print "   http://127.0.0.1:8096"
ui_print "   Tap 'Action' button in Magisk to open instantly"
ui_print ""
ui_print "  Log: /data/local/tmp/mtk_bwmod.log"
ui_print ""
ui_print "  ✓  Done — reboot to apply"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
