#!/usr/bin/env bash
# Mines Google's archived android-4.19-stable branch for CVE-tagged
# backport commits, keeps only ones touching files that actually exist
# in this tree, and drops them into patches/pending/ as ready-to-run
# patch files for cve_patch_loop.sh.
#
# Run from repo root: ./scripts/fetch_cve_candidates.sh
#
# This does NOT apply or build anything — it only populates the queue.
# Review the list before running the loop on it.

set -uo pipefail

MIRROR_DIR="${HOME}/.cache/android-4.19-common-mirror"
MIRROR_URL="https://android.googlesource.com/kernel/common"
BRANCHES=("deprecated/android-4.19-stable" "deprecated/android-4.19")
PENDING_DIR="patches/pending"
CANDIDATE_LOG="logs/cve-candidates-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$PENDING_DIR" logs

# ---- partial clone / update the mirror (blobless: fast, small) --------
if [ ! -d "$MIRROR_DIR" ]; then
    echo "[+] Cloning kernel/common mirror (partial, blobless — first run only)..."
    git clone --filter=blob:none --no-checkout "$MIRROR_URL" "$MIRROR_DIR" \
        || { echo "FATAL: clone failed — check network access to android.googlesource.com"; exit 1; }
fi

cd "$MIRROR_DIR" || exit 1
for b in "${BRANCHES[@]}"; do
    echo "[+] Fetching ${b}..."
    git fetch origin "${b}:${b}" --filter=blob:none 2>/dev/null \
        || git fetch origin "refs/heads/${b}:refs/remotes/origin/${b}" --filter=blob:none
done
cd - > /dev/null || exit 1

# ---- enumerate CVE-tagged commits across both branches -----------------
echo "[+] Scanning for CVE-tagged commits..." | tee "$CANDIDATE_LOG"

declare -A seen_shas
candidate_count=0
skipped_irrelevant=0

for b in "${BRANCHES[@]}"; do
    ref="${b}"
    git -C "$MIRROR_DIR" rev-parse --verify "$ref" >/dev/null 2>&1 || ref="origin/${b}"
    git -C "$MIRROR_DIR" rev-parse --verify "$ref" >/dev/null 2>&1 || { echo "  skip ${b}: ref not found"; continue; }

    while IFS= read -r line; do
        sha="${line%% *}"
        [ -n "${seen_shas[$sha]:-}" ] && continue
        seen_shas[$sha]=1

        subject="$(git -C "$MIRROR_DIR" log -1 --format=%s "$sha")"
        cve_id="$(echo "$subject" | grep -oE 'CVE-[0-9]{4}-[0-9]{4,7}' | head -1)"
        [ -z "$cve_id" ] && cve_id="$(git -C "$MIRROR_DIR" log -1 --format=%B "$sha" | grep -oE 'CVE-[0-9]{4}-[0-9]{4,7}' | head -1)"
        [ -z "$cve_id" ] && cve_id="uncategorized-${sha:0:8}"

        # Filter: only keep commits touching files that exist in *this* tree.
        # This is the deterministic relevance filter — no guessing.
        touched_files="$(git -C "$MIRROR_DIR" show --pretty="" --name-only "$sha")"
        relevant=false
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if [ -f "$f" ]; then
                relevant=true
                break
            fi
        done <<< "$touched_files"

        if [ "$relevant" = false ]; then
            skipped_irrelevant=$((skipped_irrelevant + 1))
            continue
        fi

        short_desc="$(echo "$subject" | tr -c 'a-zA-Z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//' | cut -c1-50)"
        out_name="${cve_id}-${short_desc}.patch"

        git -C "$MIRROR_DIR" format-patch -1 "$sha" --stdout > "${PENDING_DIR}/${out_name}" 2>/dev/null

        if [ -s "${PENDING_DIR}/${out_name}" ]; then
            echo "  [candidate] ${cve_id}  ${subject}" | tee -a "$CANDIDATE_LOG"
            candidate_count=$((candidate_count + 1))
        else
            rm -f "${PENDING_DIR}/${out_name}"
        fi
    done < <(git -C "$MIRROR_DIR" log --format="%H %s" "$ref" -- . | grep -iE 'CVE-[0-9]{4}-[0-9]{4,7}')
done

echo ""
echo "==== Done ===="
echo "Candidates queued in ${PENDING_DIR}/: ${candidate_count}"
echo "Skipped (touched files not present in this tree): ${skipped_irrelevant}"
echo "Full list: ${CANDIDATE_LOG}"
echo ""
echo "Nothing applied or built yet. Review the queue, then run:"
echo "  ./scripts/cve_patch_loop.sh"
