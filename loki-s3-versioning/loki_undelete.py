#!/usr/bin/env python3
"""Undelete Loki objects deleted since a given time by removing their delete markers.

Never touches current object versions, so data written since then is untouched.
Dry run by default; pass --apply to make changes.
"""
import argparse
import datetime

import boto3

p = argparse.ArgumentParser()
p.add_argument("--bucket", required=True)
p.add_argument("--since", required=True, help="UTC time the incident started, e.g. 2026-10-28T02:00:00Z")
p.add_argument("--prefix", action="append", required=True, help="Repeat for each prefix (chunks and index)")
p.add_argument("--apply", action="store_true")
args = p.parse_args()

since = datetime.datetime.fromisoformat(args.since.replace("Z", "+00:00"))
s3 = boto3.client("s3")
batch, count = [], 0


def flush():
    if batch and args.apply:
        resp = s3.delete_objects(Bucket=args.bucket, Delete={"Objects": batch, "Quiet": True})
        for err in resp.get("Errors", []):
            print("ERROR", err)
    batch.clear()


for prefix in args.prefix:
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=args.bucket, Prefix=prefix):
        for marker in page.get("DeleteMarkers", []):
            if marker["IsLatest"] and marker["LastModified"] >= since:
                count += 1
                if not args.apply:
                    print("would undelete", marker["Key"])
                batch.append({"Key": marker["Key"], "VersionId": marker["VersionId"]})
                if len(batch) == 1000:
                    flush()
flush()
print(f"{'undeleted' if args.apply else 'would undelete'} {count} objects")
