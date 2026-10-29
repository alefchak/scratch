# scratch

Unrelated tools and experiments, one per folder.

| Folder | What it is |
|---|---|
| [`ansible/`](ansible/) | Root password rotation with AWS Secrets Manager (module and AWS CLI versions) |
| [`flux-release-notes/`](flux-release-notes/) | Release notes and artifact downloads for a Flux-managed Kubernetes cluster |
| [`helmrelease-auto-retry/`](helmrelease-auto-retry/) | HelmRelease settings so Flux retries failed installs/upgrades on its own (e.g. an image not yet pushed) instead of staying stuck |
| [`loki-inf-cleanup/`](loki-inf-cleanup/) | Keep Loki `retention_policy="Inf"` logs forever by default; a guarded, cancelable one-off delete request for clusters that don't need them |
| [`loki-s3-versioning/`](loki-s3-versioning/) | Terraform for S3 versioning + 30-day noncurrent expiry on Loki's bucket, a deny on version purges for Loki's role, and a restore script |
| [`ec2-user-data-failfast/`](ec2-user-data-failfast/) | EC2 user-data that fails loudly: fail fast, retries with backoff, validation, and shutdown / ASG `ABANDON` + alert on failure |
| [`cisco-ntp-ldap-syslog/`](cisco-ntp-ldap-syslog/) | Notes on NTP, LDAPS login with local fallback, and remote syslog for Cisco ASA and NX-OS |
| [`terragrunt-mock-outputs/`](terragrunt-mock-outputs/) | Why Terragrunt ignores `mock_outputs` for a new, not-yet-applied dependency output, and the merge setting that fixes it |
