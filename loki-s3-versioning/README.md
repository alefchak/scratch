# Loki S3 versioning (recoverable retention deletes)

Terraform that makes Loki's S3 bucket keep deleted objects for 30 days. If retention
deletes logs by mistake (for example a retention override set by accident), the chunks and
index files can be restored.

[`main.tf`](main.tf) contains:

- **Bucket versioning.** When the compactor deletes a chunk or rewrites an index file, it
  leaves a delete marker or a previous version instead of removing the data.
- **A lifecycle rule** that permanently expires those previous versions after
  `noncurrent_days` (default 30), cleans up leftover delete markers, and aborts stale
  multipart uploads.
- **An explicit deny of `s3:DeleteObjectVersion` for Loki's IAM role.** Loki only ever does
  plain deletes, so it never needs this permission. Denying it means nothing running as
  Loki can permanently erase data, even if the role later gets broader S3 permissions.

## Usage

```sh
terraform init
terraform plan  -var loki_bucket=<bucket> -var loki_role_name=<loki-iam-role>
terraform apply -var loki_bucket=<bucket> -var loki_role_name=<loki-iam-role>
```

## Before applying

- **`aws_s3_bucket_lifecycle_configuration` replaces the bucket's entire lifecycle config.**
  Check for existing rules first (`aws s3api get-bucket-lifecycle-configuration --bucket <bucket>`)
  and copy any you find into `main.tf` as extra `rule` blocks.
- **Protection starts when versioning is enabled.** Anything deleted before then is gone.
- **Expect extra storage.** Deleted chunks are kept for 30 more days. The compactor also
  rewrites index files regularly, so older index versions build up (these are small).
- If Loki uses an IAM user instead of a role, swap `aws_iam_role_policy` for `aws_iam_user_policy`.
- Whoever runs a restore needs `s3:ListBucketVersions` and `s3:DeleteObjectVersion`. That
  person isn't Loki's role, so the deny doesn't get in the way.

## Restoring

Restoring removes the delete markers created after the incident. That brings back the previous
versions without touching current objects, so logs written since the incident are kept.

1. **Stop further deletion.** Revert whatever shortened retention, and confirm with
   `helm get values loki -n monitoring | yq '.loki.limits_config.retention_stream'`.
2. **Clear the compactor's pending deletion markers.** Chunks marked but not yet deleted are
   otherwise deleted after `retention_delete_delay`, even after the config is reverted:
   ```sh
   kubectl -n monitoring exec <compactor-or-backend-pod> -- \
     sh -c 'find /var/loki -type d -name markers -path "*retention*" -exec sh -c "rm -f \"\$1\"/*" _ {} \;'
   ```
   Adjust `/var/loki` to `compactor.working_directory`.
3. **Undelete with [`loki_undelete.py`](loki_undelete.py).** Do a dry run first, then pass `--apply`:
   ```sh
   python3 loki_undelete.py --bucket <bucket> --since 2026-10-28T02:00:00Z \
     --prefix '<tenant>/' --prefix 'index/'
   ```
   - Set `--since` slightly *before* the incident.
   - Chunks live under the tenant ID (`fake/` when `auth_enabled: false`). The index lives under
     the `schema_config` index prefix (usually `index/`). Check the paths in the bucket first.
4. **Flush the results cache,** or wait out its TTL. Then query an old time range to confirm the
   logs are back. On its next run, the compactor merges the restored index files with the
   current ones.

The dry run also lists data that other retention rules legitimately expired since the
incident. Restoring it is harmless, because the compactor expires it again on its next pass.
Rehearse the whole restore once in a non-production cluster before you need it.
