#!/bin/bash
# ============================================================
#  BAYMAX MODE — Maximum Performance Profile
#  OnePlus 8 Pro / Snapdragon 865 (kona)
#
#  Run from NetHunter chroot as root:
#    bash /data/local/baymax/baymax_mode.sh
# ============================================================

TAG="[BAYMAX]"

# --- 1. CPU: Lock all governors to performance ---
echo "$TAG Setting CPU governor to performance..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "performance" > "$gov"
done

# --- 2. CPU: Pin minimum frequency to hardware max (no throttle) ---
echo "$TAG Locking CPU min freq to hardware max..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
    MAX=$(cat "$cpu/cpuinfo_max_freq")
    echo "$MAX" > "$cpu/scaling_min_freq"
done

# --- 3. CPU: Disable deep idle states on all cores ---
# ARM CPUIDLE exposes states under /sys/devices/system/cpu/cpu*/cpuidle/state*
echo "$TAG Disabling CPU deep idle states..."
for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    [ -f "$state" ] && echo 1 > "$state"
done

# --- 4. GPU: Lock Adreno 650 governor to performance mode ---
echo "$TAG Setting GPU governor to performance..."
GPU_DEV="/sys/class/kgsl/kgsl-3d0/devfreq"
if [ -f "$GPU_DEV/governor" ]; then
    echo "performance" > "$GPU_DEV/governor"
fi

# Lock GPU min freq to max available freq
if [ -f "$GPU_DEV/available_frequencies" ]; then
    GPU_MAX=$(cat "$GPU_DEV/available_frequencies" | tr ' ' '\n' | sort -rn | head -1)
    [ -n "$GPU_MAX" ] && echo "$GPU_MAX" > "$GPU_DEV/min_freq"
fi

# --- 5. Memory: Optimise for large in-RAM model (do not swap) ---
echo "$TAG Tuning memory for LLM inference..."
echo 0 > /proc/sys/vm/swappiness          # Never swap — keep model in RAM
echo 10 > /proc/sys/vm/vfs_cache_pressure # Keep filesystem caches hot
echo 3 > /proc/sys/vm/drop_caches         # Drop stale page cache before load

# --- 6. THP: Tell kernel to aggressively collapse pages for Ollama ---
echo "$TAG Enabling aggressive Transparent Huge Pages..."
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled
fi
if [ -f /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs ]; then
    echo 100 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs
fi

# --- 7. Scheduler: Reduce latency for faster thread wakeups ---
echo "$TAG Tightening scheduler latency..."
echo 2000000 > /proc/sys/kernel/sched_latency_ns         # 2ms (default: 10ms)
echo 500000  > /proc/sys/kernel/sched_min_granularity_ns # 0.5ms slices

# --- 8. IO Scheduler: deadline for low-latency model file reads ---
echo "$TAG Setting IO scheduler to deadline..."
for q in /sys/block/*/queue/scheduler; do
    [ -f "$q" ] && echo "deadline" > "$q" 2>/dev/null
done

# --- 9. Wakelock: Prevent Android from sleeping the CPU ---
echo "$TAG Acquiring wakelock..."
echo "baymax_brain" > /sys/power/wake_lock

echo ""
echo "$TAG ██████████████████████████████████████"
echo "$TAG   BAYMAX MODE ACTIVE — LET HIM THINK  "
echo "$TAG ██████████████████████████████████████"
