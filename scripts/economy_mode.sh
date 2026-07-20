#!/bin/bash
# ============================================================
#  ECONOMY MODE — Battery Saver Profile
#  OnePlus 8 Pro / Snapdragon 865 (kona)
#
#  Run from NetHunter chroot as root:
#    bash /data/local/baymax/economy_mode.sh
# ============================================================

TAG="[ECONOMY]"

# --- 1. CPU: Restore schedutil governor (EAS-aware, battery efficient) ---
echo "$TAG Restoring CPU governor to schedutil..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "schedutil" > "$gov"
done

# --- 2. CPU: Restore min frequencies to hardware minimum ---
echo "$TAG Restoring CPU min freq to hardware minimum..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
    MIN=$(cat "$cpu/cpuinfo_min_freq")
    echo "$MIN" > "$cpu/scaling_min_freq"
done

# --- 3. CPU: Re-enable all idle states for deep sleep ---
echo "$TAG Re-enabling CPU idle states..."
for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    [ -f "$state" ] && echo 0 > "$state"
done

# --- 4. GPU: Restore Adreno TZ governor (dynamic, battery aware) ---
echo "$TAG Restoring GPU governor to msm-adreno-tz..."
GPU_DEV="/sys/class/kgsl/kgsl-3d0/devfreq"
if [ -f "$GPU_DEV/governor" ]; then
    echo "msm-adreno-tz" > "$GPU_DEV/governor"
fi

# Restore GPU min freq to lowest available
if [ -f "$GPU_DEV/available_frequencies" ]; then
    GPU_MIN=$(cat "$GPU_DEV/available_frequencies" | tr ' ' '\n' | sort -n | head -1)
    [ -n "$GPU_MIN" ] && echo "$GPU_MIN" > "$GPU_DEV/min_freq"
fi

# --- 5. Memory: Restore normal Android memory pressure settings ---
echo "$TAG Restoring memory defaults..."
echo 100 > /proc/sys/vm/swappiness          # Allow zRAM swapping
echo 100 > /proc/sys/vm/vfs_cache_pressure  # Normal cache reclaim

# --- 6. THP: Restore to madvise (only used when apps explicitly request it) ---
echo "$TAG Restoring Transparent Huge Pages to default..."
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled
fi
if [ -f /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs ]; then
    echo 10000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs
fi

# --- 7. Scheduler: Restore default Android latency targets ---
echo "$TAG Restoring scheduler defaults..."
echo 10000000 > /proc/sys/kernel/sched_latency_ns         # Default 10ms
echo 1250000  > /proc/sys/kernel/sched_min_granularity_ns # Default 1.25ms

# --- 8. IO Scheduler: Restore to zen (balanced default from boot script) ---
echo "$TAG Restoring IO scheduler to zen..."
for q in /sys/block/*/queue/scheduler; do
    [ -f "$q" ] && echo "zen" > "$q" 2>/dev/null
done

# --- 9. Release wakelock: Let Android sleep when screen is off ---
echo "$TAG Releasing wakelock..."
if [ -f /sys/power/wake_unlock ]; then
    echo "baymax_brain" > /sys/power/wake_unlock
fi

echo ""
echo "$TAG ✓ Economy mode active — phone will run cool and sip battery."
