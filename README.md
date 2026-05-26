# kitsune_thinkstation_prefetch

Helpers for **decoupling** the SRA `prefetch` step from the iridis HPC pipeline.

The HPC login nodes at iridis have a 64 GiB per-user memory cgroup limit which
causes `fasterq-dump` (and the verbose stderr that `subprocess.run(..., capture_output=True)`
buffers) to OOM-kill the launcher process on multi-GB SRRs. The Thinkstation
(`thinkstationpgx-079f`) has internet access and more headroom, so it does the
download half of the pipeline while iridis keeps doing alignment.

## Workflow

```
┌──────────────────┐                       ┌─────────────────────┐
│  Thinkstation    │   rsync .sra files   │  iridis loginX00*   │
│                  │ ───────────────────► │                     │
│  prefetch SRR... │                       │  fasterq-dump       │
│                  │                       │  STARsolo (SLURM)   │
└──────────────────┘                       └─────────────────────┘
        ▲                                            ▲
        │                                            │
   internet                                  Lustre shared FS
```

The iridis launcher's `prefetch` step is idempotent: when it finds
`<work>/sra_prefetch/<SRR>/<SRR>.sra` locally, it logs *"found locally"* and
proceeds to `fasterq-dump`. So once the Thinkstation rsyncs files into the
right path on iridis, the existing launchers pick them up without any code
changes.

## Files

| File | Purpose |
|------|---------|
| `thinkstation_prefetch_and_push.sh` | Thinkstation runner: prefetch each SRR, rsync to iridis, verify, optionally delete local copy. Resumable, parallelisable. |
| `build_thinkstation_prefetch_manifest.py` | Run on iridis to (re)generate the TSV listing pending SRRs from the master metadata CSV. |

## Thinkstation quick-start

```bash
# 1. SRA Toolkit (one-time)
cd ~ && mkdir -p tools && cd tools
curl -L https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/3.4.1/sratoolkit.3.4.1-ubuntu64.tar.gz | tar xzf -
echo 'export PATH="$HOME/tools/sratoolkit.3.4.1-ubuntu64/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
prefetch --version       # expect 3.4.1

# 2. SSH to iridis (one-time)
ssh -o StrictHostKeyChecking=accept-new lag1e24@loginX001 hostname
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_iridis -N ""
ssh-copy-id -i ~/.ssh/id_ed25519_iridis.pub lag1e24@loginX001
# optional: also for loginX002/loginX003 if you want to push there

# 3. Clone this repo + grab manifest
mkdir -p ~/prefetch_work && cd ~/prefetch_work
git clone git@github.com:Lagreen303/kitsune_thinkstation_prefetch.git
cd kitsune_thinkstation_prefetch
chmod +x thinkstation_prefetch_and_push.sh
scp loginX001:/iridisfs/ddnb/Luke/kitsune/download_align_data/results/geo_ai_metadata_tiered/thinkstation_pending_srrs.tsv .

# 4. Smoke test (one SRR end-to-end)
./thinkstation_prefetch_and_push.sh \
  --manifest thinkstation_pending_srrs.tsv \
  --iridis-user lag1e24 \
  --iridis-host loginX001 \
  --iridis-repo /iridisfs/ddnb/Luke/kitsune/download_align_data \
  --scratch ~/prefetch_scratch \
  --smoke-test SRR19608922

# 5. Full batch (background-safe)
nohup ./thinkstation_prefetch_and_push.sh \
  --manifest thinkstation_pending_srrs.tsv \
  --iridis-user lag1e24 \
  --iridis-host loginX001 \
  --iridis-repo /iridisfs/ddnb/Luke/kitsune/download_align_data \
  --scratch ~/prefetch_scratch \
  --jobs 4 \
  --resume \
  > batch.log 2>&1 &
disown
tail -f batch.log
```

## Script options

```
--manifest        TSV with columns srr<TAB>gse<TAB>sample_id (header required)
--iridis-user     remote user (e.g. lag1e24)
--iridis-host     iridis login host (loginX001, loginX002, or loginX003)
--iridis-repo     absolute path of the iridis repo root
                    e.g. /iridisfs/ddnb/Luke/kitsune/download_align_data
--scratch DIR     local scratch dir for prefetched .sra (default ./sra_scratch)
--keep-local      keep local copy after upload (default: delete on success)
--jobs N          concurrent prefetch+rsync slots (default 1)
--resume          skip SRRs whose .sra is already on iridis (default ON)
--no-resume       always re-fetch and re-upload
--smoke-test SRR  prefetch+push only this one SRR (uses manifest for gse/sample_id)
```

## Iridis-side regeneration

To rebuild the manifest later (e.g. after adding new GSEs to the master
metadata CSV, or once Thinkstation has uploaded some files and you want to
see what's still pending):

```bash
cd /iridisfs/ddnb/Luke/kitsune/download_align_data
python3 scripts/build_thinkstation_prefetch_manifest.py \
  --gse GSE205490 --gse GSE241825 --gse GSE241842 --gse GSE279904 --gse GSE135194 \
  --out results/geo_ai_metadata_tiered/thinkstation_pending_srrs.tsv
```

The same script lives in this repo for reference, but the iridis copy is
authoritative because it reads the master metadata + checks live state.
