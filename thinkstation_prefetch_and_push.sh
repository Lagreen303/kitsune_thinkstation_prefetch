#!/usr/bin/env bash
# thinkstation_prefetch_and_push.sh
#
# Run this on the Thinkstation (`thinkstationpgx-079f`) to:
#   1. prefetch SRA runs listed in a TSV manifest
#   2. rsync each completed .sra back to iridis at the expected pipeline path
#   3. (optionally) delete the local copy after a successful upload
#
# Iridis-side pipeline will then short-circuit prefetch ("found locally")
# and run fasterq-dump on the file.
#
# USAGE:
#   ./thinkstation_prefetch_and_push.sh \
#       --manifest pending_srrs.tsv \
#       --iridis-user lag1e24 \
#       --iridis-host loginX001 \
#       --iridis-repo /iridisfs/ddnb/Luke/kitsune/download_align_data \
#       [--scratch ./sra_scratch] \
#       [--keep-local]            (default: delete after upload)
#       [--jobs N]                (default: 1; parallel SRRs)
#       [--resume]                (skip SRRs already present on remote)
#       [--smoke-test SRR]        (single SRR end-to-end probe)
#
# REQUIREMENTS on Thinkstation:
#   - SRA Toolkit (prefetch on PATH or set SRATOOLKIT_BIN)
#   - rsync, ssh, awk, bash 4+
#   - SSH key to iridis (or accept-new host key on first run)

set -u
set -o pipefail

MANIFEST=""
IRIDIS_USER=""
IRIDIS_HOST=""
IRIDIS_REPO=""
SCRATCH="./sra_scratch"
KEEP_LOCAL=0
JOBS=1
RESUME=1
SMOKE_SRR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)       MANIFEST="$2"; shift 2 ;;
    --iridis-user)    IRIDIS_USER="$2"; shift 2 ;;
    --iridis-host)    IRIDIS_HOST="$2"; shift 2 ;;
    --iridis-repo)    IRIDIS_REPO="$2"; shift 2 ;;
    --scratch)        SCRATCH="$2"; shift 2 ;;
    --keep-local)     KEEP_LOCAL=1; shift ;;
    --jobs)           JOBS="$2"; shift 2 ;;
    --no-resume)      RESUME=0; shift ;;
    --resume)         RESUME=1; shift ;;
    --smoke-test)     SMOKE_SRR="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,30p' "$0" | sed -e 's/^# //;s/^#//' ; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$IRIDIS_USER" && -n "$IRIDIS_HOST" && -n "$IRIDIS_REPO" ]] \
  || { echo "ERROR: need --iridis-user, --iridis-host, --iridis-repo" >&2; exit 1; }

PREFETCH="${SRATOOLKIT_BIN:-$(command -v prefetch)}"
[[ -x "$PREFETCH" ]] || { echo "ERROR: prefetch not on PATH (or set SRATOOLKIT_BIN)" >&2; exit 1; }

mkdir -p "$SCRATCH"
LOG_DIR="${SCRATCH}/logs"
mkdir -p "$LOG_DIR"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=no -o ServerAliveInterval=30)
REMOTE="${IRIDIS_USER}@${IRIDIS_HOST}"

# ── helpers ──────────────────────────────────────────────────────────────────

remote_size() {
  # returns size in bytes if remote file exists, else empty string
  local remote_path="$1"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "stat -c '%s' '$remote_path' 2>/dev/null" 2>/dev/null
}

remote_mkdir() {
  ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$1'"
}

process_one() {
  local srr="$1"
  local gse="$2"
  local sample_id="$3"

  local local_dir="${SCRATCH}/${srr}"
  local local_sra="${local_dir}/${srr}.sra"
  local remote_dir="${IRIDIS_REPO}/results/sra_starsolo_${gse}/sra_prefetch/${srr}"
  local remote_sra="${remote_dir}/${srr}.sra"
  local logf="${LOG_DIR}/${gse}_${srr}.log"

  echo "[$(date '+%F %T')] === ${gse} ${srr} (${sample_id}) ===" | tee -a "$logf"

  if (( RESUME )); then
    local rsz
    rsz="$(remote_size "$remote_sra")"
    if [[ -n "$rsz" && "$rsz" -gt $((10*1024*1024)) ]]; then
      echo "  [resume] already on iridis (${rsz} bytes) — skip" | tee -a "$logf"
      [[ $KEEP_LOCAL -eq 0 ]] && rm -rf "$local_dir"
      return 0
    fi
  fi

  echo "  [prefetch] $srr -> $local_dir" | tee -a "$logf"
  mkdir -p "$local_dir"
  if ! "$PREFETCH" "$srr" -O "$SCRATCH" --max-size 500G >>"$logf" 2>&1; then
    echo "  [prefetch] FAILED for $srr (see $logf)" | tee -a "$logf"
    return 1
  fi

  if [[ ! -f "$local_sra" ]]; then
    echo "  [prefetch] sra file missing after prefetch ($local_sra)" | tee -a "$logf"
    return 1
  fi
  local sz; sz=$(stat -c '%s' "$local_sra")
  echo "  [prefetch] ok: ${sz} bytes" | tee -a "$logf"

  echo "  [rsync] -> ${REMOTE}:${remote_sra}" | tee -a "$logf"
  remote_mkdir "$remote_dir"
  if ! rsync -av --partial --inplace --no-compress \
       -e "ssh ${SSH_OPTS[*]}" \
       "$local_sra" "${REMOTE}:${remote_sra}" >>"$logf" 2>&1; then
    echo "  [rsync] FAILED for $srr (see $logf)" | tee -a "$logf"
    return 1
  fi

  # verify remote size matches
  local rsz2; rsz2=$(remote_size "$remote_sra")
  if [[ "$rsz2" != "$sz" ]]; then
    echo "  [verify] remote size mismatch (local=$sz remote=$rsz2)" | tee -a "$logf"
    return 1
  fi
  echo "  [verify] remote size ${rsz2} bytes ✓" | tee -a "$logf"

  if [[ $KEEP_LOCAL -eq 0 ]]; then
    rm -rf "$local_dir"
    echo "  [cleanup] removed local ${local_dir}" | tee -a "$logf"
  fi
  echo "[$(date '+%F %T')] DONE ${gse} ${srr}" | tee -a "$logf"
  return 0
}

export -f process_one remote_size remote_mkdir
export SCRATCH LOG_DIR RESUME KEEP_LOCAL IRIDIS_USER IRIDIS_HOST IRIDIS_REPO REMOTE PREFETCH
export SSH_OPTS_STR="${SSH_OPTS[*]}"
# Re-import SSH_OPTS in the subshell from string
export -f remote_size remote_mkdir process_one

# ── smoke test mode ──────────────────────────────────────────────────────────
if [[ -n "$SMOKE_SRR" ]]; then
  # Use the first manifest row with matching SRR for GSE/sample lookup,
  # or fall back to single test if manifest absent.
  if [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
    line=$(awk -v s="$SMOKE_SRR" -F'\t' '$1==s {print; exit}' "$MANIFEST")
  fi
  if [[ -z "${line:-}" ]]; then
    echo "ERROR: --smoke-test $SMOKE_SRR not in manifest (or no manifest given)" >&2
    exit 1
  fi
  read -r srr gse sample_id <<<"$(echo "$line" | tr '\t' ' ')"
  process_one "$srr" "$gse" "$sample_id"
  exit $?
fi

# ── batch mode ───────────────────────────────────────────────────────────────
[[ -f "$MANIFEST" ]] || { echo "ERROR: --manifest not found: $MANIFEST" >&2; exit 1; }

total=$(($(wc -l < "$MANIFEST") - 1))
echo "[$(date '+%F %T')] starting batch: $total SRR(s), $JOBS in parallel"
echo "  manifest:    $MANIFEST"
echo "  scratch:     $SCRATCH"
echo "  remote:      ${REMOTE}:${IRIDIS_REPO}"
echo "  keep-local:  $KEEP_LOCAL"
echo "  resume:      $RESUME"

# Sequential or parallel via xargs
tail -n +2 "$MANIFEST" \
  | awk -F'\t' 'NF>=3 {print $1"\t"$2"\t"$3}' \
  | xargs -P "$JOBS" -n 1 -I{} bash -c '
      IFS=$'"'"'\t'"'"' read -r srr gse sample_id <<<"$1"
      process_one "$srr" "$gse" "$sample_id"
    ' _ {}

echo "[$(date '+%F %T')] batch complete (or partial; see ${LOG_DIR})"
