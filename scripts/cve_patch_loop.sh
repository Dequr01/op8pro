#!/usr/bin/env bash
# CVE patch loop: apply -> incremental build -> commit -> next.
# Deterministic, no LLM in the loop. Antigravity only touches
# patches/needs-review/ separately, offline from this script.
#
# Run from repo root: ./scripts/cve_patch_loop.sh

set -uo pipefail  # deliberately NOT -e: we handle failures per-patch, not by dying

# ---- config -----------------------------------------------------------
WORK_BRANCH="cve-hardening"
DEFCONFIG="blu_spark_defconfig"          # matches your existing build.sh
OUT_DIR="out"
ARCH="arm64"
JOBS="$(nproc)"
MAX_CONSECUTIVE_FAILURES=3
PENDING_DIR="patches/pending"
APPLIED_DIR="patches/applied"
REVIEW_DIR="patches/needs-review"
FAILED_DIR="patches/failed"
LOG_DIR="logs"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="${LOG_DIR}/cve-loop-${RUN_TS}.log"

# ---- setup --------------------------------------------------------------
mkdir -p "$PENDING_DIR" "$APPLIED_DIR" "$REVIEW_DIR" "$FAILED_DIR" "$LOG_DIR"

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RUN_LOG"
}

die() {
    log "FATAL: $*"
    exit 1
}

# Refuse to run on the real branch.
current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" = "blu_spark-16-custom" ]; then
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
        log "Switching to existing ${WORK_BRANCH}"
        git checkout "$WORK_BRANCH" || die "could not switch to ${WORK_BRANCH}"
    else
        log "Creating ${WORK_BRANCH} off current HEAD"
        git checkout -b "$WORK_BRANCH" || die "could not create ${WORK_BRANCH}"
    fi
    current_branch="$WORK_BRANCH"
fi
log "Working on branch: ${current_branch}"

if [ "$current_branch" = "blu_spark-16-custom" ]; then
    die "refusing to run directly on blu_spark-16-custom"
fi

# Stop Ollama once, loudly. No silent continue if it fails — that's
# what happened last time and it's not getting repeated here.
log "Stopping Ollama to free RAM for the build..."
if ! sudo systemctl stop ollama 2>>"$RUN_LOG"; then
    if ! pkill -f ollama 2>>"$RUN_LOG"; then
        die "could not stop Ollama — aborting rather than risk an OOM mid-loop. Stop it manually and re-run."
    fi
fi
log "Ollama stopped."

shopt -s nullglob
patches=("$PENDING_DIR"/*.patch)
shopt -u nullglob

if [ ${#patches[@]} -eq 0 ]; then
    die "no patches in ${PENDING_DIR}/ — populate the queue first (see README.md)"
fi

log "Found ${#patches[@]} patch(es) in queue."

consecutive_failures=0
applied_count=0
failed_count=0
review_count=0

# ---- incremental build check -------------------------------------------
# Only compiles + links vmlinux, no AK3 packaging. Fast because out/ is
# reused between iterations — only touched objects rebuild.
build_check() {
    make -C "$(pwd)" O="$OUT_DIR" ARCH="$ARCH" "$DEFCONFIG" > "$1.defconfig.log" 2>&1 \
        && make -C "$(pwd)" O="$OUT_DIR" ARCH="$ARCH" -j"$JOBS" > "$1.build.log" 2>&1
}

for patch_path in "${patches[@]}"; do
    patch_name="$(basename "$patch_path")"
    log "---- ${patch_name} ----"

    checkpoint_tag="cve-loop-checkpoint-$(date +%s)"
    git tag "$checkpoint_tag" HEAD

    applied_clean=false

    if git am --3way "$patch_path" >> "$RUN_LOG" 2>&1; then
        applied_clean=true
        log "  applied via git am"
    else
        git am --abort >> "$RUN_LOG" 2>&1 || true
        if git apply --3way --index "$patch_path" 2>> "$RUN_LOG"; then
            git commit -m "BACKPORT: ${patch_name%.patch}

Applied via cve_patch_loop.sh, git apply --3way fallback.
Original patch: ${patch_name}" >> "$RUN_LOG" 2>&1
            applied_clean=true
            log "  applied via git apply --3way + manual commit"
        fi
    fi

    if [ "$applied_clean" = false ]; then
        log "  APPLY FAILED — routing to needs-review, not blocking loop"
        review_note="${REVIEW_DIR}/${patch_name%.patch}.context.md"
        {
            echo "# Needs manual resolution: ${patch_name}"
            echo
            echo "Failed both \`git am --3way\` and \`git apply --3way\`."
            echo "Checkpoint before attempt: ${checkpoint_tag}"
            echo
            echo "## Original patch"
            echo '```diff'
            cat "$patch_path"
            echo '```'
        } > "$review_note"
        mv "$patch_path" "$REVIEW_DIR/"
        review_count=$((review_count + 1))
        consecutive_failures=$((consecutive_failures + 1))
        git reset --hard "$checkpoint_tag" >> "$RUN_LOG" 2>&1
        git tag -d "$checkpoint_tag" >> "$RUN_LOG" 2>&1
    else
        log "  building (incremental)..."
        build_log_prefix="${LOG_DIR}/${patch_name%.patch}"
        if build_check "$build_log_prefix"; then
            log "  BUILD OK — keeping commit"
            mv "$patch_path" "$APPLIED_DIR/"
            applied_count=$((applied_count + 1))
            consecutive_failures=0
            git tag -d "$checkpoint_tag" >> "$RUN_LOG" 2>&1
            rm -f "${build_log_prefix}.defconfig.log" "${build_log_prefix}.build.log"
        else
            log "  BUILD FAILED — reverting to checkpoint, logging"
            fail_log="${FAILED_DIR}/${patch_name%.patch}.build.log"
            cat "${build_log_prefix}.build.log" "${build_log_prefix}.defconfig.log" > "$fail_log" 2>/dev/null
            rm -f "${build_log_prefix}.defconfig.log" "${build_log_prefix}.build.log"
            mv "$patch_path" "$FAILED_DIR/"
            failed_count=$((failed_count + 1))
            consecutive_failures=$((consecutive_failures + 1))
            git reset --hard "$checkpoint_tag" >> "$RUN_LOG" 2>&1
            git tag -d "$checkpoint_tag" >> "$RUN_LOG" 2>&1
        fi
    fi

    if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        log "Hit ${MAX_CONSECUTIVE_FAILURES} consecutive failures — halting rather than burning more time."
        log "Check ${LOG_DIR}/ and ${FAILED_DIR}/ / ${REVIEW_DIR}/ before re-running."
        break
    fi
done

log "==== Summary ===="
log "Applied cleanly + built: ${applied_count}"
log "Needs manual review:     ${review_count}"
log "Applied but broke build: ${failed_count}"

if [ "$applied_count" -gt 0 ]; then
    log "Running full build + AK3 packaging for final state..."
    if [ -x ./build.sh ]; then
        ./build.sh >> "$RUN_LOG" 2>&1 && log "Final build + package OK." || log "Final build FAILED — check ${RUN_LOG}."
    else
        log "build.sh not found/executable — run your normal packaging step manually."
    fi
fi

log "Branch ${current_branch} left as-is for your review. Nothing pushed, nothing touched blu_spark-16-custom."
