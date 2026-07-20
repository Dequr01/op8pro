# CVE Patch Loop — op8pro (instantnoodlep, 4.19)

Autonomous apply → compile-check → build → commit loop for backporting
CVE fixes onto blu_spark-16-custom. Runs unattended. You test the flashed
zips, not the individual commits.

## Why it's split into two pieces

An LLM agent (Antigravity) looping hundreds of times reliably, tracking
state, and not silently corrupting the tree is a bad bet — that's exactly
the "false success reports, untracked file destruction" failure mode
you already hit once on this repo. So the mechanical part (apply, build,
commit, rollback) is a deterministic bash script with no LLM in the loop.
Antigravity only gets called for the cases the script *can't* resolve
mechanically: a patch that fails clean `git am`/`git apply --3way` and
needs manual hunk resolution. That's the 10% that actually needs
judgment; the other 90% doesn't need an agent at all, just needs to not
be your afternoon.

## Directory layout (created under repo root)

```
patches/
  pending/       # CVE-YYYY-NNNNN-short-desc.patch  — queue, sorted alpha = order applied
  applied/       # moved here after clean apply + successful build
  needs-review/  # apply failed cleanly, dumped here with a context file for Antigravity
  failed/        # applied but broke the build; reverted, logged, not retried automatically
logs/
  cve-loop-<run-timestamp>.log
  <patch-name>.build.log     # kept only for entries in needs-review/ and failed/
```

## Sourcing the patch queue (separate from the loop, do this first)

The loop only *applies* patches — it doesn't invent them. Populate
`patches/pending/` before running it. Two realistic sources, in order
of trust:

1. **Archived Google `android-4.19` common-kernel branch history**
   (`android.googlesource.com/kernel/common`, tag/branch may need
   digging — it's aged out of the active branch list as of writing).
   Anything Google's kernel team already backported to this exact
   kernel generation is the safest possible source: it was written
   and tested against 4.19 semantics, not adapted from a newer tree.
2. **kernel.org CVE database / NVD**, filtered to subsystems that
   actually exist in your build (binder, ashmem, f2fs, netfilter, USB
   gadget, the specific Qualcomm drivers you ship) — skip anything in
   subsystems you don't compile in. Pull the fix commit as a
   `.patch` via `git format-patch -1 <sha>` from a local mainline
   clone, don't hand-transcribe.

Name each file `CVE-YYYY-NNNNN-short-desc.patch` so the log is
self-documenting and you can `grep` history for a specific CVE later.

## Running it

```bash
cd ~/bernel/op8
./scripts/cve_patch_loop.sh
```

Safe to walk away from. It:
- checkpoints with a git tag before every patch attempt
- tries `git am` first (keeps attribution), falls back to
  `git apply --3way`
- on clean apply: runs an **incremental** build (reuses `out/`, only
  recompiles touched files — full link/boot-image packaging only
  happens once at the very end of the whole batch, not per patch)
- build fail → `git reset --hard` to the checkpoint, patch moved to
  `failed/` with the build log attached, loop continues
- apply fail (conflicts) → patch moved to `needs-review/` with a
  generated context file, loop continues — does **not** block on it
- stops itself after 3 consecutive failures in a row (bad patch
  source, toolchain issue, whatever — better to halt than burn
  hours down a broken path) and prints a summary
- stops Ollama once at the start (not per-patch) to keep RAM headroom
  for the build; does not silently continue if that fails — it exits
  loudly instead, since a silent skip is what bit you last time

At the end: one full clean build + AK3 packaging from the final state,
same as your existing `build.sh`.

## What Antigravity's job actually is here

For everything landed in `patches/needs-review/`: point Antigravity at
the context file (original patch, the hunk that failed, current
surrounding code) and have it produce a hand-adjusted patch that
applies the *same logical fix* against your tree's actual code shape.
That's a real judgment call — fine for an agent, one file at a time,
with you glancing at the diff before it goes back into `pending/` for
the mechanical loop to pick up on the next run.

## Everything lives on its own branch

The script refuses to run if you're on `blu_spark-16-custom` directly
— it works on `cve-hardening` (created off your current HEAD if it
doesn't exist). Nothing touches your main branch until you review and
merge it yourself.
