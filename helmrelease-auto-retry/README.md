# HelmRelease auto-retry (recover from transient failures)

HelmRelease settings so Flux keeps retrying a failed install or upgrade on its
own, instead of giving up and leaving the release stuck as failed.

The case it's for: a release fails because something it needs isn't there
*yet*, most often an image that hasn't been pushed to the registry. Pods sit in
`ImagePullBackOff`, Helm times out waiting for them, and the HelmRelease is
marked failed. When the image shows up later, the pods may recover, but the
HelmRelease never does.

## Why Flux gets stuck

helm-controller judges the **Helm action**, not the current state of the pods.
With the default strategy (`RemediateOnFailure`), a failed attempt is:

1. **Remediated:** a failed install is uninstalled, a failed upgrade is rolled
   back to the last good revision.
2. **Retried:** only while there are retries left in
   `remediation.retries`, which defaults to **0**.

Once retries run out, Flux stops trying until the *desired state* changes: the
HelmRelease spec, the values, or the chart version. A late-arriving image isn't
any of those, so the release stays failed.

## The fix

[`helmrelease-retry.yaml`](helmrelease-retry.yaml) holds the fields to merge
into a HelmRelease:

```yaml
spec:
  interval: 5m
  timeout: 5m
  install:
    strategy:
      name: RetryOnFailure
      retryInterval: 2m
    remediation:
      retries: -1
  upgrade:
    strategy:
      name: RetryOnFailure
      retryInterval: 2m
    remediation:
      retries: -1
```

What each part does:

- **`strategy.name: RetryOnFailure`** (install and upgrade): on failure, retry
  every `retryInterval` **without** uninstalling or rolling back. A failed
  install is retried as an upgrade. Once the image exists, the next attempt
  succeeds and the HelmRelease goes Ready. `retryInterval` defaults to `5m`.
- **`remediation.retries: -1`**: unlimited retry budget. With
  `RetryOnFailure` this mostly doesn't apply, but helm-controller still reads
  it in a couple of edge cases (for example a release that has failed before
  and whose Helm storage Secret then goes missing). Leaving it at the default
  `0` can make Flux refuse to reinstall with "retries exhausted". `-1` closes
  that gap.
- **`timeout`**: how long each attempt waits for pods to become ready. Raise
  it if the image usually lands within a few minutes, so the first attempt
  can just wait it out.

## Older Flux (no `strategy` field)

If the API server rejects `spec.install.strategy` / `spec.upgrade.strategy`,
the installed helm-controller predates `RetryOnFailure`. Check with
`flux version`. Drop both `strategy` blocks and keep only:

```yaml
spec:
  install:
    remediation:
      retries: -1
  upgrade:
    remediation:
      retries: -1
```

This also recovers on its own, but each failed upgrade rolls back to the old
revision before retrying, so the release flips between versions until the new
one succeeds.

## Unsticking a release that's already failed

Changing the spec as above resets the counters on its own. To kick one without
a spec change (Flux 2.2+):

```sh
flux reconcile helmrelease <name> -n <ns> --reset   # clear retry counters, try again
flux reconcile helmrelease <name> -n <ns> --force   # one-off install/upgrade right now
```

## Trade-offs

- **No automatic rollback.** With `RetryOnFailure`, a genuinely broken upgrade
  stays deployed (and keeps being retried) instead of being rolled back. Fine
  for "waiting on an image", worse for a bad chart change. Alert on
  HelmRelease `Ready=False` so a permanently failing release isn't silent.
- **Doesn't fix the race itself.** Pushing the image before the chart or
  values change is committed (CI gating, or Flux image automation) avoids the
  failure in the first place.

## References

- [Flux docs: HelmRelease install/upgrade strategy](https://fluxcd.io/flux/components/helm/helmreleases/)
- [helm-controller #1278: `RetryOnFailure` strategy](https://github.com/fluxcd/helm-controller/issues/1278)
- [cozystack #3554: `RetryOnFailure` with nil remediation refusing to reinstall](https://github.com/cozystack/cozystack/issues/3554)
- [Flux v2.2.0 release notes (`--reset` / `--force`)](https://fluxcd.io/blog/2023/12/flux-v2.2.0/)
