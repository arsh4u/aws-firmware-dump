#!/usr/bin/env python3
"""Stream an EBS snapshot as a raw disk image on stdout, via the EBS direct APIs.

Why this exists
---------------
A volume derived from an AWS Marketplace snapshot carries the product code, and
AWS only permits such a volume to be attached as the ROOT device of a STOPPED
instance ("Marketplace codes may not be attached as a secondary device"). That
rules out snapshot -> volume -> attach-to-helper.

The EBS direct APIs read snapshot content over HTTPS with no attach at all:

    ListSnapshotBlocks  -> allocated blocks (512 KiB each) + tokens
    GetSnapshotBlock    -> that block's bytes

Design notes
------------
* Output goes to STDOUT as a plain raw stream, so the caller can pipe it
  straight into zstd and S3. Nothing large ever touches the helper's disk.
* Blocks are fetched concurrently but emitted strictly in index order; block
  indexes that are not allocated are emitted as zero-filled blocks so the
  resulting image has the correct byte offsets.
* The EBS direct API speaks CBOR and uses PascalCase members. In particular the
  per-block Checksum is base64 of the raw digest, NOT a hex string.

A JSON summary is written to --stats-out (progress goes to stderr), leaving
stdout purely the image data.
"""

import argparse
import base64
import concurrent.futures
import hashlib
import itertools
import json
import os
import sys
import time
import urllib.request

import boto3
from botocore.config import Config

BLOCK_SIZE = 512 * 1024
ZEROS = b"\0" * BLOCK_SIZE


def resolve_region(explicit):
    """Region for the EBS/EC2 clients.

    boto3 does NOT fall back to instance metadata for region the way the AWS CLI
    does, so on an EC2 helper with no region in env/config it raises
    NoRegionError. Resolve it explicitly: argument, then env, then IMDS (v2 with
    a v1 fallback).
    """
    if explicit:
        return explicit
    for key in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        val = os.environ.get(key)
        if val:
            return val
    try:
        token = None
        try:
            req = urllib.request.Request(
                "http://169.254.169.254/latest/api/token", method="PUT",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
            token = urllib.request.urlopen(req, timeout=3).read().decode()
        except Exception:
            pass
        req = urllib.request.Request(
            "http://169.254.169.254/latest/meta-data/placement/availability-zone")
        if token:
            req.add_header("X-aws-ec2-metadata-token", token)
        az = urllib.request.urlopen(req, timeout=3).read().decode()
        if az:
            return az[:-1]  # strip the trailing zone letter
    except Exception:
        pass
    return None


def iter_blocks(ebs, snapshot_id):
    """Yield (block_index, block_token) for every allocated block, ascending."""
    kwargs = {"SnapshotId": snapshot_id, "MaxResults": 1000}
    while True:
        resp = ebs.list_snapshot_blocks(**kwargs)
        for blk in resp.get("Blocks", []):
            yield blk["BlockIndex"], blk["BlockToken"]
        token = resp.get("NextToken")
        if not token:
            return
        kwargs["NextToken"] = token


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--snapshot-id", required=True)
    ap.add_argument("--region", default=None)
    ap.add_argument("--workers", type=int, default=32)
    ap.add_argument("--stats-out", default=None,
                    help="write a JSON summary here (stdout is the image)")
    ap.add_argument("--skip-verify", action="store_true",
                    help="skip per-block checksum verification (faster, less safe)")
    args = ap.parse_args()

    cfg = Config(max_pool_connections=max(64, args.workers * 2),
                 retries={"max_attempts": 8, "mode": "adaptive"})
    region = resolve_region(args.region)
    if not region:
        print("ERROR: no AWS region available (pass --region, set AWS_REGION, or run on EC2)",
              file=sys.stderr)
        return 2
    print(f"region={region}", file=sys.stderr, flush=True)
    session = boto3.session.Session(region_name=region)
    ec2 = session.client("ec2", config=cfg)
    ebs = session.client("ebs", config=cfg)

    snap = ec2.describe_snapshots(SnapshotIds=[args.snapshot_id])["Snapshots"][0]
    total_bytes = int(snap["VolumeSize"]) * 1024 ** 3
    print(f"snapshot={args.snapshot_id} volume={snap['VolumeSize']}GiB "
          f"out=stdout workers={args.workers}", file=sys.stderr, flush=True)

    out = sys.stdout.buffer
    started = time.time()
    stats = {"snapshot_id": args.snapshot_id, "volume_bytes": total_bytes,
             "allocated_blocks": 0, "allocated_bytes": 0, "emitted_bytes": 0,
             "block_size": BLOCK_SIZE}
    next_index = 0
    written = 0

    def fetch(item):
        idx, token = item
        resp = ebs.get_snapshot_block(
            SnapshotId=args.snapshot_id, BlockIndex=idx, BlockToken=token)
        data = resp["BlockData"]
        if hasattr(data, "read"):
            data = data.read()
        length = int(resp.get("DataLength", len(data)))
        if length != len(data):
            data = data[:length]
        if not args.skip_verify:
            algo = (resp.get("ChecksumAlgorithm") or "SHA256").lower()
            expected = base64.b64decode(resp["Checksum"])
            actual = hashlib.new(algo, data).digest()
            if actual != expected:
                raise RuntimeError(
                    f"checksum mismatch at block {idx}: "
                    f"expected {resp['Checksum']} "
                    f"got {base64.b64encode(actual).decode()}")
        return idx, data

    def emit(idx, data):
        """Write one block, padding any gap with zeros to keep offsets correct."""
        nonlocal next_index, written
        gap = idx - next_index
        if gap > 0:
            for _ in range(gap):
                out.write(ZEROS)
                written += BLOCK_SIZE
        out.write(data)
        written += len(data)
        next_index = idx + 1

    chunk_size = max(1, args.workers * 4)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        block_iter = iter_blocks(ebs, args.snapshot_id)
        while True:
            chunk = list(itertools.islice(block_iter, chunk_size))
            if not chunk:
                break
            # map() preserves input order, so emission stays index-ordered
            for idx, data in pool.map(fetch, chunk):
                emit(idx, data)
                stats["allocated_blocks"] += 1
                stats["allocated_bytes"] += len(data)
                if stats["allocated_blocks"] % 2000 == 0:
                    rate = written / max(time.time() - started, 0.001)
                    print(f"  {stats['allocated_blocks']} blocks, "
                          f"{written / 2**30:.2f} GiB out, {rate / 2**20:.0f} MiB/s",
                          file=sys.stderr, flush=True)

    # pad the unallocated tail so the image is exactly volume-sized
    tail = total_bytes - written
    if tail > 0:
        for _ in range(tail // BLOCK_SIZE):
            out.write(ZEROS)
            written += BLOCK_SIZE
        rem = total_bytes - written
        if rem:
            out.write(ZEROS[:rem])
            written += rem
    out.flush()

    stats["emitted_bytes"] = written
    stats["elapsed_s"] = round(time.time() - started, 1)
    if args.stats_out:
        with open(args.stats_out, "w") as fh:
            json.dump(stats, fh)
            fh.write("\n")
    print(json.dumps(stats), file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main())
