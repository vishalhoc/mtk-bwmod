#!/system/bin/sh
# =============================================================================
# MTK Extreme Bandwidth Mod — Web Control Panel CGI API
# by hoc
# Handles: Status telemetry, Profile switching, Custom parameter tuning
# =============================================================================

printf "Content-Type: application/json\r\n"
printf "Cache-Control: no-cache, no-store, must-revalidate\r\n"
printf "Access-Control-Allow-Origin: *\r\n"
printf "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
printf "Access-Control-Allow-Headers: Content-Type\r\n\r\n"

PROFILE_FILE="/data/local/tmp/mtk_bwmod_profile"
CUSTOM_SH="/data/local/tmp/mtk_bwmod_custom.sh"
LOG_FILE="/data/local/tmp/mtk_bwmod.log"

log() {
    echo "[$(date '+%H:%M:%S')] [API] $*" >> "$LOG_FILE" 2>/dev/null
}

# Read request data
METHOD="$REQUEST_METHOD"
QUERY="$QUERY_STRING"

if [ "$METHOD" = "POST" ]; then
    read -r POST_DATA
fi

# URL decode helper
urldecode() {
    echo "$1" | sed -e 's/+/ /g' -e 's/%20/ /g' -e 's/%3A/:/g' -e 's/%2F/\//g' -e 's/%26/\&/g' -e 's/%3D/=/g' -e 's/%3F/?/g' -e 's/%22/"/g' -e 's/%2C/,/g'
}

# Parse query string param: get_param "action"
get_param() {
    echo "$QUERY" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d'=' -f2-
}

# Parse post data param: get_post_param "profile"
get_post_param() {
    echo "$POST_DATA" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d'=' -f2-
}

ACTION=$(get_param "action")
if [ -z "$ACTION" ]; then
    ACTION=$(get_post_param "action")
fi

# =============================================================================
# ACTION: REBOOT
# =============================================================================
if [ "$ACTION" = "reboot" ]; then
    printf "{\"success\":true,\"message\":\"Device rebooting now...\"}\n"
    (sleep 1; /system/bin/reboot || svc power reboot || setprop sys.powerctl reboot) &
    exit 0
fi

CPUS=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 8)
case "$CPUS" in
    10) BIG_MASK="3c0" ;;
    8)  BIG_MASK="f0"  ;;
    6)  BIG_MASK="38"  ;;
    *)  BIG_MASK="06"  ;;
esac
if [ "$CPUS" -eq 8 ] && [ -d /sys/devices/system/cpu/cpu7 ]; then
    A76_MASK="c0"  # Cores 6 & 7 (Cortex-A76 Big Cores on MT6853)
else
    A76_MASK="$BIG_MASK"
fi
HALF=$((CPUS / 2))

# =============================================================================
# PROFILE IMPLEMENTATIONS
# =============================================================================
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
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600 2>/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2                  2>/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2              2>/dev/null
    sysctl -w net.ipv4.ip_no_pmtu_disc=0                     2>/dev/null

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

    # IRQ affinity to big cores (parse /proc/interrupts directly)
    for irq in $(awk -F: '/wlan|wifi|musb|ccci|rmnet|conn|MD_|mtk_cmdq/ {print $1}' /proc/interrupts 2>/dev/null | tr -d ' '); do
        [ -f "/proc/irq/$irq/smp_affinity" ] && echo "$A76_MASK" > "/proc/irq/$irq/smp_affinity" 2>/dev/null
    done

    setprop persist.sys.wifi.power_save false
    setprop wifi.ps.mode 0
    setprop persist.env.fastdorm.enabled false
    setprop persist.vendor.radio.fd.disable 1
    log "Applied Extreme Performance profile"
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
    sysctl -w net.core.netdev_budget_usecs=2000              2>/dev/null
    sysctl -w net.core.netdev_max_backlog=16384              2>/dev/null
    sysctl -w net.netfilter.nf_conntrack_max=500000          2>/dev/null
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=1200 2>/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2                  2>/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2              2>/dev/null
    sysctl -w net.ipv4.ip_no_pmtu_disc=0                     2>/dev/null

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
    log "Applied Balanced profile"
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
    sysctl -w net.core.netdev_budget_usecs=1000              2>/dev/null
    sysctl -w net.core.netdev_max_backlog=8192               2>/dev/null
    sysctl -w net.netfilter.nf_conntrack_max=65536           2>/dev/null
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=432000 2>/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2                  2>/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2              2>/dev/null

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
    log "Applied Battery Saver profile"
}

# =============================================================================
# ACTION: APPLY PROFILE
# =============================================================================
if [ "$ACTION" = "apply_profile" ]; then
    REQ_PROFILE=$(get_param "profile")
    [ -z "$REQ_PROFILE" ] && REQ_PROFILE=$(get_post_param "profile")

    case "$REQ_PROFILE" in
        performance)
            apply_performance >/dev/null 2>&1
            echo "performance" > "$PROFILE_FILE"
            echo "{\"success\":true,\"profile\":\"performance\",\"message\":\"Extreme Performance profile applied\"}"
            exit 0
            ;;
        balanced)
            apply_balanced >/dev/null 2>&1
            echo "balanced" > "$PROFILE_FILE"
            echo "{\"success\":true,\"profile\":\"balanced\",\"message\":\"Balanced profile applied\"}"
            exit 0
            ;;
        battery)
            apply_battery >/dev/null 2>&1
            echo "battery" > "$PROFILE_FILE"
            echo "{\"success\":true,\"profile\":\"battery\",\"message\":\"Battery Saver profile applied\"}"
            exit 0
            ;;
        custom)
            if [ -f "$CUSTOM_SH" ]; then
                sh "$CUSTOM_SH" >/dev/null 2>&1
                echo "custom" > "$PROFILE_FILE"
                echo "{\"success\":true,\"profile\":\"custom\",\"message\":\"Custom parameters restored and applied\"}"
            else
                echo "{\"success\":false,\"message\":\"No custom configuration script found\"}"
            fi
            exit 0
            ;;
        *)
            echo "{\"success\":false,\"message\":\"Unknown profile: $REQ_PROFILE\"}"
            exit 0
            ;;
    esac
fi

# =============================================================================
# ACTION: SAVE CUSTOM OPTIONS
# =============================================================================
if [ "$ACTION" = "save_custom" ]; then
    # Create persistent custom script
    echo "#!/system/bin/sh" > "$CUSTOM_SH"
    echo "# MTK BWMod Custom Applied Settings - $(date)" >> "$CUSTOM_SH"

    # Helper to apply and record sysctl
    apply_sysctl() {
        KEY="$1"
        VAL="$2"
        if [ -n "$VAL" ]; then
            sysctl -w "$KEY=$VAL" >/dev/null 2>&1
            echo "sysctl -w $KEY=\"$VAL\" 2>/dev/null" >> "$CUSTOM_SH"
        fi
    }

    # Helper to apply and record setprop
    apply_prop() {
        KEY="$1"
        VAL="$2"
        if [ -n "$VAL" ]; then
            setprop "$KEY" "$VAL" 2>/dev/null
            echo "setprop $KEY \"$VAL\" 2>/dev/null" >> "$CUSTOM_SH"
        fi
    }

    # 1. TCP / IP Stack
    CC=$(urldecode "$(get_post_param 'tcp_congestion_control')")
    [ -n "$CC" ] && apply_sysctl "net.ipv4.tcp_congestion_control" "$CC"

    RMEM_MAX=$(get_post_param "rmem_max")
    [ -n "$RMEM_MAX" ] && apply_sysctl "net.core.rmem_max" "$RMEM_MAX"

    WMEM_MAX=$(get_post_param "wmem_max")
    [ -n "$WMEM_MAX" ] && apply_sysctl "net.core.wmem_max" "$WMEM_MAX"

    TCP_RMEM=$(urldecode "$(get_post_param 'tcp_rmem')")
    [ -n "$TCP_RMEM" ] && apply_sysctl "net.ipv4.tcp_rmem" "$TCP_RMEM"

    TCP_WMEM=$(urldecode "$(get_post_param 'tcp_wmem')")
    [ -n "$TCP_WMEM" ] && apply_sysctl "net.ipv4.tcp_wmem" "$TCP_WMEM"

    TFO=$(get_post_param "tcp_fastopen")
    [ -n "$TFO" ] && apply_sysctl "net.ipv4.tcp_fastopen" "$TFO"

    TS=$(get_post_param "tcp_timestamps")
    [ -n "$TS" ] && apply_sysctl "net.ipv4.tcp_timestamps" "$TS"

    SACK=$(get_post_param "tcp_sack")
    [ -n "$SACK" ] && apply_sysctl "net.ipv4.tcp_sack" "$SACK"

    FACK=$(get_post_param "tcp_fack")
    [ -n "$FACK" ] && apply_sysctl "net.ipv4.tcp_fack" "$FACK"

    ECN=$(get_post_param "tcp_ecn")
    [ -n "$ECN" ] && apply_sysctl "net.ipv4.tcp_ecn" "$ECN"

    MTU_PROBE=$(get_post_param "tcp_mtu_probing")
    [ -n "$MTU_PROBE" ] && apply_sysctl "net.ipv4.tcp_mtu_probing" "$MTU_PROBE"

    SS_IDLE=$(get_post_param "tcp_slow_start_after_idle")
    [ -n "$SS_IDLE" ] && apply_sysctl "net.ipv4.tcp_slow_start_after_idle" "$SS_IDLE"

    LOWAT=$(get_post_param "tcp_notsent_lowat")
    [ -n "$LOWAT" ] && apply_sysctl "net.ipv4.tcp_notsent_lowat" "$LOWAT"

    KEEPTIME=$(get_post_param "tcp_keepalive_time")
    [ -n "$KEEPTIME" ] && apply_sysctl "net.ipv4.tcp_keepalive_time" "$KEEPTIME"

    KEEPINTVL=$(get_post_param "tcp_keepalive_intvl")
    [ -n "$KEEPINTVL" ] && apply_sysctl "net.ipv4.tcp_keepalive_intvl" "$KEEPINTVL"

    KEEPPROBES=$(get_post_param "tcp_keepalive_probes")
    [ -n "$KEEPPROBES" ] && apply_sysctl "net.ipv4.tcp_keepalive_probes" "$KEEPPROBES"

    FINTIMEOUT=$(get_post_param "tcp_fin_timeout")
    [ -n "$FINTIMEOUT" ] && apply_sysctl "net.ipv4.tcp_fin_timeout" "$FINTIMEOUT"

    # 2. UDP Memory
    UDP_RMIN=$(get_post_param "udp_rmem_min")
    [ -n "$UDP_RMIN" ] && apply_sysctl "net.ipv4.udp_rmem_min" "$UDP_RMIN"

    UDP_WMIN=$(get_post_param "udp_wmem_min")
    [ -n "$UDP_WMIN" ] && apply_sysctl "net.ipv4.udp_wmem_min" "$UDP_WMIN"

    UDP_MEM=$(urldecode "$(get_post_param 'udp_mem')")
    [ -n "$UDP_MEM" ] && apply_sysctl "net.ipv4.udp_mem" "$UDP_MEM"

    # 3. Core Netdev & Interfaces
    BUDGET=$(get_post_param "netdev_budget")
    [ -n "$BUDGET" ] && apply_sysctl "net.core.netdev_budget" "$BUDGET"

    BUDGET_US=$(get_post_param "netdev_budget_usecs")
    [ -n "$BUDGET_US" ] && apply_sysctl "net.core.netdev_budget_usecs" "$BUDGET_US"

    BACKLOG=$(get_post_param "netdev_max_backlog")
    [ -n "$BACKLOG" ] && apply_sysctl "net.core.netdev_max_backlog" "$BACKLOG"

    RPS_FLOW=$(get_post_param "rps_sock_flow_entries")
    [ -n "$RPS_FLOW" ] && apply_sysctl "net.core.rps_sock_flow_entries" "$RPS_FLOW"

    TXQLEN=$(get_post_param "txqueuelen")
    if [ -n "$TXQLEN" ]; then
        for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
            ip link set "$IF" txqueuelen "$TXQLEN" 2>/dev/null
        done
        echo "for IF in \$(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,\"\",\$2);print \$2}' | grep -vE \"^lo$|^dummy|^ip6\"); do ip link set \"\$IF\" txqueuelen $TXQLEN 2>/dev/null; done" >> "$CUSTOM_SH"
    fi

    # Qdisc
    QDISC=$(get_post_param "qdisc_type")
    if [ -n "$QDISC" ]; then
        for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
            [ "$(iw dev "$IF" info 2>/dev/null | grep -c "type AP")" -gt "0" ] && continue
            [ "$(tc qdisc show dev "$IF" 2>/dev/null | grep -c "qdisc mq")" -gt "0" ] && continue
            tc qdisc del dev "$IF" root 2>/dev/null
            tc qdisc add dev "$IF" root "$QDISC" 2>/dev/null
        done
        echo "for IF in \$(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,\"\",\$2);print \$2}' | grep -vE \"^lo$|^dummy|^ip6\"); do [ \"\$(iw dev \"\$IF\" info 2>/dev/null | grep -c \"type AP\")\" -gt \"0\" ] && continue; [ \"\$(tc qdisc show dev \"\$IF\" 2>/dev/null | grep -c \"qdisc mq\")\" -gt \"0\" ] && continue; tc qdisc del dev \"\$IF\" root 2>/dev/null; tc qdisc add dev \"\$IF\" root $QDISC 2>/dev/null; done" >> "$CUSTOM_SH"
    fi

    # HW Offload
    GRO_VAL=$(get_post_param "hw_gro")
    GSO_VAL=$(get_post_param "hw_gso")
    TSO_VAL=$(get_post_param "hw_tso")
    if [ -n "$GRO_VAL" ] || [ -n "$GSO_VAL" ] || [ -n "$TSO_VAL" ]; then
        GRO_OPT=""
        [ "$GRO_VAL" = "1" ] && GRO_OPT="gro on" || [ "$GRO_VAL" = "0" ] && GRO_OPT="gro off"
        GSO_OPT=""
        [ "$GSO_VAL" = "1" ] && GSO_OPT="gso on" || [ "$GSO_VAL" = "0" ] && GSO_OPT="gso off"
        TSO_OPT=""
        [ "$TSO_VAL" = "1" ] && TSO_OPT="tso on" || [ "$TSO_VAL" = "0" ] && TSO_OPT="tso off"

        for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
            ethtool -K "$IF" $GRO_OPT $GSO_OPT $TSO_OPT 2>/dev/null
        done
        echo "for IF in \$(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,\"\",\$2);print \$2}' | grep -vE \"^lo$|^dummy|^ip6\"); do ethtool -K \"\$IF\" $GRO_OPT $GSO_OPT $TSO_OPT 2>/dev/null; done" >> "$CUSTOM_SH"
    fi

    # 4. IRQ Affinity & Schedutil
    AFF_MASK=$(get_post_param "cpu_affinity_mask")
    if [ -n "$AFF_MASK" ]; then
        for irq in $(awk -F: '/wlan|wifi|musb|ccci|rmnet|conn|MD_|mtk_cmdq/ {print $1}' /proc/interrupts 2>/dev/null | tr -d ' '); do
            [ -f "/proc/irq/$irq/smp_affinity" ] && echo "$AFF_MASK" > "/proc/irq/$irq/smp_affinity" 2>/dev/null
        done
        echo "for irq in \$(awk -F: '/wlan|wifi|musb|ccci|rmnet|conn|MD_|mtk_cmdq/ {print \$1}' /proc/interrupts 2>/dev/null | tr -d ' '); do [ -f \"/proc/irq/\$irq/smp_affinity\" ] && echo \"$AFF_MASK\" > \"/proc/irq/\$irq/smp_affinity\" 2>/dev/null; done" >> "$CUSTOM_SH"
    fi

    UP_RATE=$(get_post_param "schedutil_up_rate_limit_us")
    DOWN_RATE=$(get_post_param "schedutil_down_rate_limit_us")
    if [ -n "$UP_RATE" ] || [ -n "$DOWN_RATE" ]; then
        for DIR in /sys/devices/system/cpu/cpu*/cpufreq/schedutil/; do
            N=$(echo "$DIR" | grep -o 'cpu[0-9]*' | tr -dc '0-9')
            [ "$N" -ge "$HALF" ] 2>/dev/null || continue
            [ -n "$UP_RATE" ] && echo "$UP_RATE" > "${DIR}up_rate_limit_us" 2>/dev/null
            [ -n "$DOWN_RATE" ] && echo "$DOWN_RATE" > "${DIR}down_rate_limit_us" 2>/dev/null
        done
        echo "for DIR in /sys/devices/system/cpu/cpu*/cpufreq/schedutil/; do N=\$(echo \"\$DIR\" | grep -o 'cpu[0-9]*' | tr -dc '0-9'); [ \"\$N\" -ge $HALF ] 2>/dev/null || continue; [ -n \"$UP_RATE\" ] && echo \"$UP_RATE\" > \"\${DIR}up_rate_limit_us\" 2>/dev/null; [ -n \"$DOWN_RATE\" ] && echo \"$DOWN_RATE\" > \"\${DIR}down_rate_limit_us\" 2>/dev/null; done" >> "$CUSTOM_SH"
    fi

    # IRQ Coalescing
    RX_US=$(get_post_param "irq_rx_usecs")
    TX_US=$(get_post_param "irq_tx_usecs")
    RX_FR=$(get_post_param "irq_rx_frames")
    TX_FR=$(get_post_param "irq_tx_frames")
    if [ -n "$RX_US" ] || [ -n "$TX_US" ]; then
        [ -z "$RX_US" ] && RX_US=50
        [ -z "$TX_US" ] && TX_US=50
        [ -z "$RX_FR" ] && RX_FR=32
        [ -z "$TX_FR" ] && TX_FR=32
        for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
            ethtool -C "$IF" rx-usecs "$RX_US" tx-usecs "$TX_US" rx-frames "$RX_FR" tx-frames "$TX_FR" 2>/dev/null
        done
        echo "for IF in \$(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,\"\",\$2);print \$2}' | grep -vE \"^lo$|^dummy|^ip6\"); do ethtool -C \"\$IF\" rx-usecs $RX_US tx-usecs $TX_US rx-frames $RX_FR tx-frames $TX_FR 2>/dev/null; done" >> "$CUSTOM_SH"
    fi

    # 5. Conntrack
    CT_MAX=$(get_post_param "nf_conntrack_max")
    [ -n "$CT_MAX" ] && apply_sysctl "net.netfilter.nf_conntrack_max" "$CT_MAX"

    CT_EST=$(get_post_param "nf_conntrack_tcp_timeout_established")
    [ -n "$CT_EST" ] && apply_sysctl "net.netfilter.nf_conntrack_tcp_timeout_established" "$CT_EST"

    CT_TW=$(get_post_param "nf_conntrack_tcp_timeout_time_wait")
    [ -n "$CT_TW" ] && apply_sysctl "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "$CT_TW"

    CT_UDP=$(get_post_param "nf_conntrack_udp_timeout")
    [ -n "$CT_UDP" ] && apply_sysctl "net.netfilter.nf_conntrack_udp_timeout" "$CT_UDP"

    # 6. Radio & 5G Props
    NR_EN=$(get_post_param "nr_enabled")
    if [ -n "$NR_EN" ]; then
        apply_prop "persist.vendor.radio.nr.enabled" "$NR_EN"
        [ "$NR_EN" = "1" ] && apply_prop "persist.vendor.radio.force_nr" "true" || apply_prop "persist.vendor.radio.force_nr" "false"
    fi

    NR_SA=$(get_post_param "nr_sa_mode")
    [ -n "$NR_SA" ] && apply_prop "persist.vendor.radio.nr_sa_mode" "$NR_SA"

    NR_NSA=$(get_post_param "nr_nsa_mode")
    [ -n "$NR_NSA" ] && apply_prop "persist.vendor.radio.nr_nsa_mode" "$NR_NSA"

    ENDC=$(get_post_param "endc_enabled")
    [ -n "$ENDC" ] && apply_prop "persist.vendor.radio.endc_enabled" "$ENDC"

    LTE_CA=$(get_post_param "lte_ca_enabled")
    if [ -n "$LTE_CA" ]; then
        apply_prop "persist.vendor.radio.lte_ul_ca" "$LTE_CA"
        apply_prop "persist.vendor.radio.lte_dl_ca" "$LTE_CA"
        [ "$LTE_CA" = "1" ] && apply_prop "persist.vendor.radio.force_lte_ca" "true" || apply_prop "persist.vendor.radio.force_lte_ca" "false"
    fi

    VOLTE=$(get_post_param "volte_enabled")
    if [ -n "$VOLTE" ]; then
        apply_prop "persist.vendor.radio.volte_enabled" "$VOLTE"
        apply_prop "persist.dbg.volte_avail_ovr" "$VOLTE"
        apply_prop "persist.dbg.ims_volte_enable" "$VOLTE"
    fi

    VONR=$(get_post_param "vonr_enabled")
    [ -n "$VONR" ] && apply_prop "persist.vendor.radio.vonr_enabled" "$VONR"

    VILTE=$(get_post_param "vilte_enabled")
    [ -n "$VILTE" ] && apply_prop "persist.vendor.radio.vilte_enabled" "$VILTE"

    WFC=$(get_post_param "wfc_enabled")
    [ -n "$WFC" ] && apply_prop "persist.vendor.radio.wfc_support" "$WFC"

    QAM256=$(get_post_param "qam256_enabled")
    if [ -n "$QAM256" ]; then
        apply_prop "persist.vendor.radio.nr_256qam" "$QAM256"
        apply_prop "persist.vendor.radio.lte_256qam" "$QAM256"
    fi

    FD_OFF=$(get_post_param "fastdorm_disable")
    if [ -n "$FD_OFF" ]; then
        apply_prop "persist.vendor.radio.fd.disable" "$FD_OFF"
        [ "$FD_OFF" = "1" ] && apply_prop "persist.env.fastdorm.enabled" "false" || apply_prop "persist.env.fastdorm.enabled" "true"
    fi

    # 7. Wi-Fi & DNS Props
    WIFI_PS=$(get_post_param "wifi_power_save")
    if [ -n "$WIFI_PS" ]; then
        [ "$WIFI_PS" = "1" ] && PS_BOOL="true" || PS_BOOL="false"
        apply_prop "persist.sys.wifi.power_save" "$PS_BOOL"
        apply_prop "wifi.ps.mode" "$WIFI_PS"
    fi

    PREF_5G=$(get_post_param "wifi_5ghz_preferred")
    [ -n "$PREF_5G" ] && apply_prop "wifi.5ghz.preferred" "$PREF_5G"

    ROAM_FAST=$(get_post_param "wifi_fast_roam")
    if [ -n "$ROAM_FAST" ]; then
        apply_prop "persist.vendor.mtk.wifi.dot11k" "$ROAM_FAST"
        apply_prop "persist.vendor.mtk.wifi.dot11v" "$ROAM_FAST"
        apply_prop "persist.vendor.mtk.wifi.dot11r" "$ROAM_FAST"
    fi

    BF_FEEDBACK=$(get_post_param "wifi_beamforming")
    if [ -n "$BF_FEEDBACK" ]; then
        apply_prop "persist.vendor.mtk.wifi.su_bfee" "$BF_FEEDBACK"
        apply_prop "persist.vendor.mtk.wifi.mu_bfee" "$BF_FEEDBACK"
    fi

    WMM_QOS=$(get_post_param "wifi_wmm_qos")
    if [ -n "$WMM_QOS" ]; then
        apply_prop "persist.vendor.mtk.wifi.wmm_ac_vo" "$WMM_QOS"
        apply_prop "persist.vendor.mtk.wifi.wmm_ac_vi" "$WMM_QOS"
        apply_prop "persist.vendor.mtk.wifi.uapsd_enable" "$WMM_QOS"
    fi

    DNS1=$(urldecode "$(get_post_param 'custom_dns1')")
    DNS2=$(urldecode "$(get_post_param 'custom_dns2')")
    if [ -n "$DNS1" ]; then
        apply_prop "net.dns1" "$DNS1"
        [ -n "$DNS2" ] && apply_prop "net.dns2" "$DNS2"
        for IF in $(ip link show up 2>/dev/null | awk -F': ' '/^[0-9]+/{gsub(/@.*/,"",$2); print $2}' | grep -vE "^lo$|^dummy"); do
            setprop "net.${IF}.dns1" "$DNS1" 2>/dev/null
            [ -n "$DNS2" ] && setprop "net.${IF}.dns2" "$DNS2" 2>/dev/null
        done
        echo "for IF in \$(ip link show up 2>/dev/null | awk -F': ' '/^[0-9]+/{gsub(/@.*/,\"\",\$2); print \$2}' | grep -vE \"^lo$|^dummy\"); do setprop \"net.\${IF}.dns1\" \"$DNS1\" 2>/dev/null; [ -n \"$DNS2\" ] && setprop \"net.\${IF}.dns2\" \"$DNS2\" 2>/dev/null; done" >> "$CUSTOM_SH"
    fi

    # 8. Arbitrary Custom Commands (Safe)
    CUSTOM_CMD=$(urldecode "$(get_post_param 'arbitrary_cmd')")
    if [ -n "$CUSTOM_CMD" ]; then
        echo "$CUSTOM_CMD" | while read -r line; do
            case "$line" in
                sysctl*|setprop*|echo*|tc*|ip*|ethtool*)
                    eval "$line" 2>/dev/null
                    echo "$line" >> "$CUSTOM_SH"
                    ;;
            esac
        done
    fi

    chmod 755 "$CUSTOM_SH" 2>/dev/null
    echo "custom" > "$PROFILE_FILE"
    log "Applied and saved Custom User parameters"

    echo "{\"success\":true,\"profile\":\"custom\",\"message\":\"Custom parameters successfully applied and saved\"}"
    exit 0
fi

# =============================================================================
# ACTION: RESET DEFAULTS
# =============================================================================
if [ "$ACTION" = "reset_defaults" ]; then
    apply_performance >/dev/null 2>&1
    rm -f "$CUSTOM_SH" 2>/dev/null
    echo "performance" > "$PROFILE_FILE"
    echo "{\"success\":true,\"profile\":\"performance\",\"message\":\"Reset to Extreme Performance defaults\"}"
    exit 0
fi

# =============================================================================
# ACTION: PING DIAGNOSTIC
# =============================================================================
if [ "$ACTION" = "ping" ]; then
    HOST=$(get_param "host")
    [ -z "$HOST" ] && HOST="1.1.1.1"
    # Basic sanitize
    HOST=$(echo "$HOST" | tr -dc 'a-zA-Z0-9.-')
    PING_RES=$(ping -c 3 -W 2 "$HOST" 2>&1 | tr '\n' '|' | sed 's/"/\\"/g')
    echo "{\"success\":true,\"host\":\"$HOST\",\"output\":\"$PING_RES\"}"
    exit 0
fi

# =============================================================================
# ACTION: GET LOG
# =============================================================================
if [ "$ACTION" = "get_log" ]; then
    LOGS=$(tail -n 80 "$LOG_FILE" 2>/dev/null | tr '\n' '|' | sed 's/"/\\"/g')
    echo "{\"success\":true,\"log\":\"$LOGS\"}"
    exit 0
fi

# =============================================================================
# DEFAULT ACTION: GET FULL STATE / TELEMETRY
# =============================================================================
CURRENT_PROF=$(cat "$PROFILE_FILE" 2>/dev/null)
[ -z "$CURRENT_PROF" ] && CURRENT_PROF="performance"

# Helper for safe numeric JSON values
num() {
    v=$(echo "$1" | tr -dc '0-9-')
    [ -z "$v" ] && echo "0" || echo "$v"
}

# Device hardware
MODEL=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
BRAND=$(getprop ro.product.brand 2>/dev/null || echo "Unknown")
SOC=$(getprop ro.vendor.mediatek.platform 2>/dev/null)
[ -z "$SOC" ] && SOC=$(getprop ro.soc.model 2>/dev/null)
[ -z "$SOC" ] && SOC=$(getprop ro.board.platform 2>/dev/null || echo "MT6853")
case "$SOC" in
    *6853*|*MT6853*) SOC_NAME="Dimensity 720 ($SOC)" ;;
    *6877*|*MT6877*) SOC_NAME="Dimensity 900 ($SOC)" ;;
    *6833*|*MT6833*) SOC_NAME="Dimensity 700 ($SOC)" ;;
    *6893*|*MT6893*) SOC_NAME="Dimensity 1200 ($SOC)" ;;
    *6983*|*MT6983*) SOC_NAME="Dimensity 9000 ($SOC)" ;;
    *) SOC_NAME="$SOC" ;;
esac
ANDROID=$(getprop ro.build.version.release 2>/dev/null || echo "13")
UPTIME=$(num "$(awk '{print int($1)}' /proc/uptime 2>/dev/null)")
MEM_TOTAL=$(num "$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')")
MEM_FREE=$(num "$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')")

# TCP Stack Live (convert all tabs/newlines to single spaces)
TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "$TCP_CC")
RMEM_MAX=$(num "$(sysctl -n net.core.rmem_max 2>/dev/null)")
WMEM_MAX=$(num "$(sysctl -n net.core.wmem_max 2>/dev/null)")
TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr '\t\r\n' '   ' | tr -s ' ')
TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr '\t\r\n' '   ' | tr -s ' ')
TCP_TFO=$(num "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)")
TCP_TS=$(num "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null)")
TCP_SACK=$(num "$(sysctl -n net.ipv4.tcp_sack 2>/dev/null)")
TCP_FACK=$(num "$(sysctl -n net.ipv4.tcp_fack 2>/dev/null)")
TCP_ECN=$(num "$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)")
TCP_MTU_PROBE=$(num "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)")
TCP_SS_IDLE=$(num "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)")
TCP_LOWAT=$(num "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)")
TCP_KEEPTIME=$(num "$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)")
TCP_KEEPINTVL=$(num "$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)")
TCP_KEEPPROBES=$(num "$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)")
TCP_FINTIMEOUT=$(num "$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null)")

# UDP
UDP_RMIN=$(num "$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null)")
UDP_WMIN=$(num "$(sysctl -n net.ipv4.udp_wmem_min 2>/dev/null)")
UDP_MEM=$(sysctl -n net.ipv4.udp_mem 2>/dev/null | tr '\t\r\n' '   ' | tr -s ' ')

# Core
NETDEV_BUDGET=$(num "$(sysctl -n net.core.netdev_budget 2>/dev/null)")
NETDEV_BUDGET_US=$(num "$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null)")
NETDEV_BACKLOG=$(num "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)")
RPS_FLOWS=$(num "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)")

# Conntrack
CT_MAX=$(num "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)")
CT_COUNT=$(num "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)")
CT_EST=$(num "$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null)")
CT_TW=$(num "$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_time_wait 2>/dev/null)")
CT_UDP=$(num "$(sysctl -n net.netfilter.nf_conntrack_udp_timeout 2>/dev/null)")

# Schedutil Big-Core Rate Limits
UP_RATE=$(num "$(cat "/sys/devices/system/cpu/cpu${HALF}/cpufreq/schedutil/up_rate_limit_us" 2>/dev/null)")
DOWN_RATE=$(num "$(cat "/sys/devices/system/cpu/cpu${HALF}/cpufreq/schedutil/down_rate_limit_us" 2>/dev/null)")

# Fast single-process IRQ Count
IRQ_COUNT=$(num "$(awk -F: '/wlan|wifi|musb|ccci|rmnet|conn|MD_|mtk_cmdq/ {print $1}' /proc/interrupts 2>/dev/null | wc -l)")

# Radio & Cellular Props
NR_EN=$(getprop persist.vendor.radio.nr.enabled 2>/dev/null || echo "0")
NR_SA=$(getprop persist.vendor.radio.nr_sa_mode 2>/dev/null || echo "0")
NR_NSA=$(getprop persist.vendor.radio.nr_nsa_mode 2>/dev/null || echo "0")
ENDC=$(getprop persist.vendor.radio.endc_enabled 2>/dev/null || echo "0")
LTE_CA=$(getprop persist.vendor.radio.lte_ul_ca 2>/dev/null || echo "0")
VOLTE=$(getprop persist.vendor.radio.volte_enabled 2>/dev/null || echo "0")
VONR=$(getprop persist.vendor.radio.vonr_enabled 2>/dev/null || echo "0")
VILTE=$(getprop persist.vendor.radio.vilte_enabled 2>/dev/null || echo "0")
WFC=$(getprop persist.vendor.radio.wfc_support 2>/dev/null || echo "0")
QAM256=$(getprop persist.vendor.radio.nr_256qam 2>/dev/null || echo "0")
FD_OFF=$(getprop persist.vendor.radio.fd.disable 2>/dev/null || echo "0")

# Wi-Fi & DNS Props
WIFI_PS_MODE=$(getprop wifi.ps.mode 2>/dev/null || echo "0")
PREF_5G=$(getprop wifi.5ghz.preferred 2>/dev/null || echo "0")
ROAM_11K=$(getprop persist.vendor.mtk.wifi.dot11k 2>/dev/null || echo "0")
BF_BFEE=$(getprop persist.vendor.mtk.wifi.su_bfee 2>/dev/null || echo "0")
WMM_VO=$(getprop persist.vendor.mtk.wifi.wmm_ac_vo 2>/dev/null || echo "0")
DNS1=$(getprop net.dns1 2>/dev/null || echo "")
DNS2=$(getprop net.dns2 2>/dev/null || echo "")

# Fast Interfaces enumeration
IF_LIST="["
FIRST=1
for IF in $(ip -o link show up 2>/dev/null | awk -F': ' '{gsub(/@.*/,"",$2);print $2}' | grep -vE "^lo$|^dummy|^ip6"); do
    IP=$(ip -4 addr show dev "$IF" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d'/' -f1)
    MAC=$(cat "/sys/class/net/$IF/address" 2>/dev/null)
    MTU=$(num "$(cat "/sys/class/net/$IF/mtu" 2>/dev/null)")
    TXQ=$(num "$(cat "/sys/class/net/$IF/tx_queue_len" 2>/dev/null)")
    QDISC=$(cat "/sys/class/net/$IF/queuing" 2>/dev/null)
    [ -z "$QDISC" ] && QDISC=$(tc qdisc show dev "$IF" 2>/dev/null | head -1 | awk '{print $2}')
    [ -z "$QDISC" ] && QDISC="none"
    RX_BYTES=$(num "$(cat "/sys/class/net/$IF/statistics/rx_bytes" 2>/dev/null)")
    TX_BYTES=$(num "$(cat "/sys/class/net/$IF/statistics/tx_bytes" 2>/dev/null)")
    RX_PKTS=$(num "$(cat "/sys/class/net/$IF/statistics/rx_packets" 2>/dev/null)")
    TX_PKTS=$(num "$(cat "/sys/class/net/$IF/statistics/tx_packets" 2>/dev/null)")

    [ "$MTU" = "0" ] && MTU=1500
    [ "$TXQ" = "0" ] && TXQ=1000

    [ "$FIRST" = "0" ] && IF_LIST="$IF_LIST,"
    IF_LIST="$IF_LIST{\"name\":\"$IF\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"mtu\":$MTU,\"txq\":$TXQ,\"qdisc\":\"$QDISC\",\"rx_bytes\":$RX_BYTES,\"tx_bytes\":$TX_BYTES,\"rx_pkts\":$RX_PKTS,\"tx_pkts\":$TX_PKTS}"
    FIRST=0
done
IF_LIST="$IF_LIST]"

# Construct final JSON
cat <<EOF
{
  "profile": "$CURRENT_PROF",
  "device": {
    "model": "$MODEL",
    "brand": "$BRAND",
    "soc": "$SOC_NAME",
    "android": "$ANDROID",
    "cpus": $CPUS,
    "big_mask": "$A76_MASK",
    "ram_total_kb": $MEM_TOTAL,
    "ram_free_kb": $MEM_FREE,
    "uptime_secs": $UPTIME
  },
  "tcp": {
    "cc": "$TCP_CC",
    "available_cc": "$AVAIL_CC",
    "rmem_max": $RMEM_MAX,
    "wmem_max": $WMEM_MAX,
    "tcp_rmem": "$TCP_RMEM",
    "tcp_wmem": "$TCP_WMEM",
    "tcp_fastopen": $TCP_TFO,
    "tcp_timestamps": $TCP_TS,
    "tcp_sack": $TCP_SACK,
    "tcp_fack": $TCP_FACK,
    "tcp_ecn": $TCP_ECN,
    "tcp_mtu_probing": $TCP_MTU_PROBE,
    "tcp_slow_start_after_idle": $TCP_SS_IDLE,
    "tcp_notsent_lowat": $TCP_LOWAT,
    "tcp_keepalive_time": $TCP_KEEPTIME,
    "tcp_keepalive_intvl": $TCP_KEEPINTVL,
    "tcp_keepalive_probes": $TCP_KEEPPROBES,
    "tcp_fin_timeout": $TCP_FINTIMEOUT
  },
  "udp": {
    "udp_rmem_min": $UDP_RMIN,
    "udp_wmem_min": $UDP_WMIN,
    "udp_mem": "$UDP_MEM"
  },
  "core": {
    "netdev_budget": $NETDEV_BUDGET,
    "netdev_budget_usecs": $NETDEV_BUDGET_US,
    "netdev_max_backlog": $NETDEV_BACKLOG,
    "rps_sock_flow_entries": $RPS_FLOWS
  },
  "conntrack": {
    "max": $CT_MAX,
    "count": $CT_COUNT,
    "tcp_timeout_established": $CT_EST,
    "tcp_timeout_time_wait": $CT_TW,
    "udp_timeout": $CT_UDP
  },
  "schedutil": {
    "up_rate_limit_us": $UP_RATE,
    "down_rate_limit_us": $DOWN_RATE
  },
  "irq": {
    "count": $IRQ_COUNT,
    "mask": "$A76_MASK"
  },
  "radio": {
    "nr_enabled": "$NR_EN",
    "nr_sa_mode": "$NR_SA",
    "nr_nsa_mode": "$NR_NSA",
    "endc_enabled": "$ENDC",
    "lte_ca": "$LTE_CA",
    "volte": "$VOLTE",
    "vonr": "$VONR",
    "vilte": "$VILTE",
    "wfc": "$WFC",
    "qam256": "$QAM256",
    "fastdorm_disable": "$FD_OFF"
  },
  "wifi": {
    "ps_mode": "$WIFI_PS_MODE",
    "preferred_5g": "$PREF_5G",
    "roaming_fast": "$ROAM_11K",
    "beamforming": "$BF_BFEE",
    "wmm_qos": "$WMM_VO",
    "dns1": "$DNS1",
    "dns2": "$DNS2"
  },
  "interfaces": $IF_LIST
}
EOF
exit 0
