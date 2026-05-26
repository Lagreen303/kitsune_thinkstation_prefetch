#!/usr/bin/env python3
"""
Build a pending-SRR manifest for the Thinkstation prefetch workflow.

For each GSE we want, list every SRR that does NOT yet have either:
  - a complete .sra at <work>/sra_prefetch/<SRR>/<SRR>.sra, OR
  - a complete 10x FASTQ pair at <work>/fastq/<sample_id>/<SRR>_*.fastq

Writes a TSV the Thinkstation script consumes.
"""
import argparse
import csv
import sys
from pathlib import Path


def has_complete_sra(prefetch_dir, srr):
    p = prefetch_dir / srr / f"{srr}.sra"
    return p.is_file() and p.stat().st_size > 10 * 1024 * 1024


def has_complete_fastq_pair(fastq_dir, srr):
    """Same 10x layout checks the iridis pipeline uses."""
    def exists(suffix):
        return (
            (fastq_dir / f"{srr}_{suffix}.fastq").is_file()
            or (fastq_dir / f"{srr}_{suffix}.fastq.gz").is_file()
        )
    if exists("3") and exists("4"):
        return True
    if exists("2") and exists("3") and not exists("4"):
        return True
    if exists("1") and exists("2") and not exists("3"):
        return True
    return False


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--metadata",
        type=Path,
        default=Path(
            "results/geo_ai_metadata_tiered/all_gse_metadata_10x_sra_available.csv",
        ),
        help="Master metadata CSV with columns srr,gse,sample_id",
    )
    p.add_argument(
        "--results-root",
        type=Path,
        default=Path("results"),
        help="Iridis 'results' dir containing sra_starsolo_<GSE>/ per study",
    )
    p.add_argument("--gse", action="append", required=True,
                   help="Repeat for each GSE to include (e.g. --gse GSE205490)")
    p.add_argument("--out", type=Path, required=True,
                   help="TSV output: srr<TAB>gse<TAB>sample_id")
    args = p.parse_args()

    if not args.metadata.is_file():
        sys.exit(f"metadata not found: {args.metadata}")

    targets = set(g.upper() for g in args.gse)
    rows = []
    with args.metadata.open(encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for r in reader:
            if r.get("gse", "").strip().upper() in targets:
                rows.append(dict((k, (v or "").strip()) for k, v in r.items()))

    if not rows:
        sys.exit("no rows in metadata for --gse {}".format(args.gse))

    pending = []
    counts = {}
    for r in rows:
        gse, srr, sample_id = r["gse"], r["srr"], r["sample_id"]
        counts.setdefault(gse, {"total": 0, "have_sra": 0, "have_fastq": 0, "pending": 0})
        counts[gse]["total"] += 1
        work = args.results_root / f"sra_starsolo_{gse}"
        sra_dir = work / "sra_prefetch"
        fq_dir = work / "fastq" / sample_id
        if has_complete_sra(sra_dir, srr):
            counts[gse]["have_sra"] += 1
            continue
        if has_complete_fastq_pair(fq_dir, srr):
            counts[gse]["have_fastq"] += 1
            continue
        pending.append((srr, gse, sample_id))
        counts[gse]["pending"] += 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as fh:
        fh.write("srr\tgse\tsample_id\n")
        for srr, gse, sample_id in pending:
            fh.write("{}\t{}\t{}\n".format(srr, gse, sample_id))

    print("Wrote {} pending SRR row(s) to {}".format(len(pending), args.out))
    for gse in sorted(counts):
        c = counts[gse]
        print("  {:12s} total={:4d}  have_sra={:4d}  have_fastq={:4d}  PENDING={:4d}".format(
            gse, c["total"], c["have_sra"], c["have_fastq"], c["pending"]))


if __name__ == "__main__":
    main()
