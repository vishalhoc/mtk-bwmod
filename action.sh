#!/system/bin/sh
# =============================================================================
# MTK Extreme Bandwidth Mod v2.0 — action.sh
# Dual Mode: Magisk Action Launcher (Web Control Panel) + Interactive Switcher
# Authors: Elvan · Web Control Panel & Custom Tuner by hoc
# =============================================================================

PORT=8096
PROFILE_FILE="/data/local/tmp/mtk_bwmod_profile"
CUSTOM_SH="/data/local/tmp/mtk_bwmod_custom.sh"
LOG="/data/local/tmp/mtk_bwmod.log"
WEB_DIR="/data/local/mtk_bwmod/web"
MODDIR="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="/data/adb/modules/mtk_bwmod"

log() { echo "[$(date '+%H:%M:%S')] [ACTION] $*" >> "$LOG" 2>/dev/null; }

CPUS=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 8)
case "$CPUS" in
  10) BIG_MASK="3c0" ;;
   8) BIG_MASK="f0"  ;;
   6) BIG_MASK="38"  ;;
   *) BIG_MASK="06"  ;;
esac
if [ "$CPUS" -eq 8 ] && [ -d /sys/devices/system/cpu/cpu7 ]; then
  A76_MASK="c0"  # Cores 6 & 7 (Cortex-A76 Big Cores on MT6853)
else
  A76_MASK="$BIG_MASK"
fi
HALF=$((CPUS / 2))

# ── 1. SYNC & ENSURE WEB SERVER IS RUNNING ──────────────────────────────────
# Normalize any backslash filenames from Windows zip extraction
mkdir -p "$MODDIR/web/cgi-bin" 2>/dev/null
for f in "$MODDIR"/*; do
  base=$(basename "$f")
  case "$base" in
    web\\index.html) mv "$f" "$MODDIR/web/index.html" 2>/dev/null ;;
    web\\cgi-bin\\api.sh) mv "$f" "$MODDIR/web/cgi-bin/api.sh" 2>/dev/null ;;
  esac
done

mkdir -p "$WEB_DIR/cgi-bin" 2>/dev/null
if [ -d "$MODDIR/web" ]; then
  cp -rf "$MODDIR/web/"* "$WEB_DIR/" 2>/dev/null
fi
chmod -R 0755 "$WEB_DIR" 2>/dev/null
chmod 0755 "$WEB_DIR/cgi-bin/api.sh" 2>/dev/null

BUSYBOX=""
for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox $(which busybox 2>/dev/null); do
  if [ -x "$b" ]; then BUSYBOX="$b"; break; fi
done

if ! pgrep -f "httpd -p .*:$PORT" >/dev/null 2>&1; then
  if [ -n "$BUSYBOX" ] && [ -f "$WEB_DIR/index.html" ]; then
    $BUSYBOX httpd -p 0.0.0.0:$PORT -h "$WEB_DIR"
    log "Started httpd on port $PORT"
  fi
fi

# ── 2. CLI ARGUMENT HANDLING (DIRECT APPLY) ──────────────────────────────────
apply_performance() {
  sysctl -w net.core.rmem_max=67108864                     2>/dev/null
  sysctl -w net.core.wmem_max=67108864                     2>/dev/null
  sysctl -w net.ipv4.tcp_rmem="4096 1048576 67108864"      2>/dev/null
  sysctl -w net.ipv4.tcp_wmem="4096 1048576 67108864"      2>/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bic            2>/dev/null \
    || sysctl -w net.ipv4.tcp_congestion_control=bbr       2>/dev/null \
    || sysctl -w net.ipv4.tcp_congestion_control=cubic     2>/dev/null
  sysctl -w net.ipv4.tcp_fastopen=3                        2>/dev/null
  sysctl -w net.ipv4.tcp_timestamps=0                      2>/dev/null
  sysctl -w net.ipv4.tcp_mtu_probing=2                     2>/dev/null
  sysctl -w net.ipv4.tcp_slow_start_after_idle=0           2>/dev/null
  sysctl -w net.ipv4.tcp_notsent_lowat=131072              2>/dev/null
  sysctl -w net.core.netdev_budget=600                     2>/dev/null
  sysctl -w net.core.netdev_budget_usecs=4000              2>/dev/null
  sysctl -w net.core.netdev_max_backlog=32768              2>/dev/null
  sysctl -w net.core.rps_sock_flow_entries=32768           2>/dev/null
  sysctl -w net.netfilter.nf_conntrack_max=2000000         2>/dev/null
  for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
    [ "$(iw dev "$IF" info 2>/dev/null | grep -c "type AP")" -gt "0" ] && continue
    [ "$(tc qdisc show dev "$IF" 2>/dev/null | grep -c "qdisc mq")" -gt "0" ] && continue
    tc qdisc del dev "$IF" root 2>/dev/null
    tc qdisc add dev "$IF" root fq 2>/dev/null \
      || tc qdisc add dev "$IF" root fq_codel 2>/dev/null \
      || tc qdisc add dev "$IF" root pfifo_fast 2>/dev/null
    ip link set "$IF" txqueuelen 3000 2>/dev/null
  done
  for DIR in /sys/devices/system/cpu/cpu*/cpufreq/schedutil/; do
    N=$(echo "$DIR" | grep -o 'cpu[0-9]*' | tr -dc '0-9')
    [ "$N" -ge "$HALF" ] 2>/dev/null || continue
    echo 0   > "${DIR}up_rate_limit_us"   2>/dev/null
    echo 500 > "${DIR}down_rate_limit_us" 2>/dev/null
  done
  # Steer network interrupts to Cortex-A76 Big Cores
  for irq in $(awk -F: '/wlan|wifi|musb|ccci|rmnet|conn|MD_|mtk_cmdq/ {print $1}' /proc/interrupts 2>/dev/null | tr -d ' '); do
    [ -f "/proc/irq/$irq/smp_affinity" ] && echo "$A76_MASK" > "/proc/irq/$irq/smp_affinity" 2>/dev/null
  done
  setprop persist.sys.wifi.power_save false
  setprop wifi.ps.mode 0
  setprop persist.env.fastdorm.enabled false
  setprop persist.vendor.radio.fd.disable 1
}

apply_balanced() {
  sysctl -w net.core.rmem_max=33554432                     2>/dev/null
  sysctl -w net.core.wmem_max=33554432                     2>/dev/null
  sysctl -w net.ipv4.tcp_rmem="4096 524288 33554432"       2>/dev/null
  sysctl -w net.ipv4.tcp_wmem="4096 524288 33554432"       2>/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bic            2>/dev/null \
    || sysctl -w net.ipv4.tcp_congestion_control=cubic     2>/dev/null
  sysctl -w net.ipv4.tcp_timestamps=1                      2>/dev/null
  sysctl -w net.ipv4.tcp_mtu_probing=1                     2>/dev/null
  sysctl -w net.ipv4.tcp_slow_start_after_idle=1           2>/dev/null
  sysctl -w net.core.netdev_budget=400                     2>/dev/null
  sysctl -w net.core.netdev_max_backlog=16384              2>/dev/null
  sysctl -w net.netfilter.nf_conntrack_max=500000          2>/dev/null
  for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
    [ "$(iw dev "$IF" info 2>/dev/null | grep -c "type AP")" -gt "0" ] && continue
    [ "$(tc qdisc show dev "$IF" 2>/dev/null | grep -c "qdisc mq")" -gt "0" ] && continue
    tc qdisc del dev "$IF" root 2>/dev/null
    tc qdisc add dev "$IF" root fq_codel 2>/dev/null \
      || tc qdisc add dev "$IF" root pfifo_fast 2>/dev/null
    ip link set "$IF" txqueuelen 2000 2>/dev/null
  done
  for DIR in /sys/devices/system/cpu/cpu*/cpufreq/schedutil/; do
    N=$(echo "$DIR" | grep -o 'cpu[0-9]*' | tr -dc '0-9')
    [ "$N" -ge "$HALF" ] 2>/dev/null || continue
    echo 200  > "${DIR}up_rate_limit_us"   2>/dev/null
    echo 1000 > "${DIR}down_rate_limit_us" 2>/dev/null
  done
  setprop persist.sys.wifi.power_save false
  setprop wifi.ps.mode 0
  setprop persist.env.fastdorm.enabled false
  setprop persist.vendor.radio.fd.disable 0
}

apply_battery() {
  sysctl -w net.core.rmem_max=16777216                     2>/dev/null
  sysctl -w net.core.wmem_max=16777216                     2>/dev/null
  sysctl -w net.ipv4.tcp_rmem="4096 262144 16777216"       2>/dev/null
  sysctl -w net.ipv4.tcp_wmem="4096 262144 16777216"       2>/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=cubic          2>/dev/null \
    || sysctl -w net.ipv4.tcp_congestion_control=reno      2>/dev/null
  sysctl -w net.ipv4.tcp_timestamps=1                      2>/dev/null
  sysctl -w net.ipv4.tcp_mtu_probing=0                     2>/dev/null
  sysctl -w net.ipv4.tcp_slow_start_after_idle=1           2>/dev/null
  sysctl -w net.core.netdev_budget=300                     2>/dev/null
  sysctl -w net.core.netdev_max_backlog=8192               2>/dev/null
  sysctl -w net.netfilter.nf_conntrack_max=65536           2>/dev/null
  for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
    [ "$(iw dev "$IF" info 2>/dev/null | grep -c "type AP")" -gt "0" ] && continue
    [ "$(tc qdisc show dev "$IF" 2>/dev/null | grep -c "qdisc mq")" -gt "0" ] && continue
    tc qdisc del dev "$IF" root 2>/dev/null
    tc qdisc add dev "$IF" root fq_codel 2>/dev/null \
      || tc qdisc add dev "$IF" root pfifo_fast 2>/dev/null
    ip link set "$IF" txqueuelen 1000 2>/dev/null
  done
  for DIR in /sys/devices/system/cpu/cpu*/cpufreq/schedutil/; do
    echo 500  > "${DIR}up_rate_limit_us"   2>/dev/null
    echo 2000 > "${DIR}down_rate_limit_us" 2>/dev/null
  done
  setprop persist.sys.wifi.power_save true
  setprop wifi.ps.mode 1
  setprop persist.env.fastdorm.enabled true
  setprop persist.vendor.radio.fd.disable 0
}

if [ "$1" = "apply" ] && [ -n "$2" ]; then
  case "$2" in
    performance) apply_performance; echo "performance" > "$PROFILE_FILE" ;;
    balanced)    apply_balanced;    echo "balanced" > "$PROFILE_FILE" ;;
    battery)     apply_battery;     echo "battery" > "$PROFILE_FILE" ;;
    custom)      [ -f "$CUSTOM_SH" ] && sh "$CUSTOM_SH"; echo "custom" > "$PROFILE_FILE" ;;
  esac
  echo "✓ Applied profile: $2"
  exit 0
fi

# ── 3. LAUNCH BROWSER INTENT ────────────────────────────────────────────────
am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT" >/dev/null 2>&1

CURRENT=$(cat "$PROFILE_FILE" 2>/dev/null || echo "performance")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MTK Extreme Bandwidth Mod"
echo "  Control Panel & Profile Switcher"
echo "  by Elvan · WebUI & Tuner by hoc"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  ✓ Web Control Panel launched at:"
echo "    http://127.0.0.1:$PORT"
echo ""
echo "  Active Profile : $CURRENT"
echo "  Server Status  : RUNNING (Port $PORT)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log "Action triggered: WebUI opened on port $PORT"
exit 0
