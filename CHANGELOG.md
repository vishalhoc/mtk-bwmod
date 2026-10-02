# MTK Extreme Bandwidth Mod Changelog

## v2.0 - Web Control Panel, Live Telemetry & Full Parameter Tuner
- **Interactive Web Control Panel**:
  - Embedded BusyBox `httpd` daemon on port `8096` (`http://localhost:8096`).
  - Dark cyberpunk UI with real-time hardware ticker (SoC, Device, Active Profile, TCP CC, Conntrack, Uptime).
- **Magisk Action Button**:
  - One-tap access directly from the Magisk App via `actionTitle=Open BWMod Control Panel`.
  - Dual-mode `action.sh` supporting GUI browser launch, CLI profile switcher, and headless apply.
- **Dynamic Profile Switcher**:
  - ⚡ **Extreme Performance**: 64MB socket buffers, BBR/BIC, fq qdisc, 0µs schedutil reaction, 600 NAPI budget, 2M conntrack table, WiFi power save OFF, Fast Dormancy OFF.
  - ⚖️ **Balanced**: 32MB socket buffers, BBR/Cubic, fq_codel, 200µs schedutil reaction, 400 NAPI budget, 500K conntrack table.
  - 🔋 **Battery Saver**: 16MB buffers, Cubic, fq_codel, 500µs schedutil, 300 NAPI, aggressive modem sleep & WiFi power save ON.
  - 🛠️ **Custom Profile**: Fully user-tunable with boot-persistent restoration script (`/data/local/tmp/mtk_bwmod_custom.sh`).
- **Comprehensive Options Editor**:
  - Tune TCP CC, buffer vectors (`rmem_max`, `wmem_max`, `tcp_rmem`, `tcp_wmem`), TFO, timestamps, SACK, ECN, MTU probing, slow start after idle, keepalives.
  - Tune NAPI netdev budget, backlog, RPS sock flow entries, txqueuelen, qdisc (`fq`, `fq_codel`, `pfifo_fast`), HW offloading (GRO/GSO/TSO).
  - Tune big-core IRQ affinity masks, schedutil up/down rate limits, IRQ coalescing batch window.
  - Tune Netfilter & Conntrack table size and TCP timeouts.
  - Tune 5G NR flags (SA/NSA), EN-DC, LTE Carrier Aggregation, VoLTE, VoNR, 256-QAM, and Fast Dormancy.
  - Tune Wi-Fi QoS, 5GHz preference, 802.11k/v/r roaming, beamforming CSI feedback, and custom DNS (Cloudflare, Google, Quad9, AdGuard).
  - Arbitrary custom commands editor executing directly into kernel sysctl/properties.
- **Live Diagnostics & Logs**:
  - In-browser network ping diagnostic tool.
  - Live module & kernel logging viewer.
- **Bugfixes & Optimizations**:
  - Fixed JSON parser control character / tab violations by sanitizing sysctl vectors.
  - Replaced slow IRQ folder iteration with high-performance single-pass pipelines.
  - Added safe numeric fallbacks across all kernel properties.
