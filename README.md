# scratch

Unrelated tools and experiments, one per folder.

| Folder | What it is |
|---|---|
| [`ansible/`](ansible/) | Root password rotation with AWS Secrets Manager (module and AWS CLI versions) |
| [`flux-release-notes/`](flux-release-notes/) | Release notes and artifact downloads for a Flux-managed Kubernetes cluster |
| [`helmrelease-auto-retry/`](helmrelease-auto-retry/) | HelmRelease settings so Flux retries failed installs/upgrades on its own (e.g. an image not yet pushed) instead of staying stuck |
| [`loki-retention-override/`](loki-retention-override/) | Out-of-band Flux patch to override a Loki `retention_stream` period without committing it |
