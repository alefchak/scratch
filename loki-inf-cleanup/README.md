# Loki Inf log cleanup (one-off delete requests)

Keeps `{retention_policy="Inf"}` logs **forever by default in every cluster**. In clusters that
don't need them, an occasional, deliberate, cancelable delete request removes old ones.

## Why this approach

Config is promoted dev → test → prod as whole-repo merges, and per-cluster values come from a
`substituteFrom` ConfigMap. Any retention *setting* that shortens Inf logs could end up in a
keep-forever cluster by accident: through a merge, a copy-pasted cluster-vars entry, or the wrong
kube context. Guards can reduce that risk but can't eliminate it.

Here, no shortening setting exists anywhere:

- **Git** has one rule: keep Inf logs forever. Nothing to override, so nothing to promote by mistake.
- **Clusters that don't need the logs** run [`delete-inf-logs.sh`](delete-inf-logs.sh) by hand when
  storage starts to matter (e.g. quarterly). Nothing persists in the cluster afterwards.
- **Keep-forever clusters** need nothing. There's no setting in them that could go wrong.

Every request also has a built-in undo window: Loki waits `delete_request_cancel_period` (24h
by default) before processing it.

## Prerequisites (Loki config in Git)

- `compactor.retention_enabled: true`
- `compactor.delete_request_store` set to your object store
- `limits_config.deletion_mode: filter-and-delete`

Tools on the machine running the script: `kubectl`, `curl`, `jq`.

## Running a cleanup

```sh
kubectl config use-context <cluster that does NOT need Inf logs>
KEEP_DAYS=30 TENANT=<tenant> ./delete-inf-logs.sh
```

The script shows the context, query and time window, and **refuses to continue unless you type
the context name**. It then port-forwards to Loki, submits the request, and lists pending requests.

| Variable | Default | Meaning |
|---|---|---|
| `KEEP_DAYS` | `30` | Keep the most recent N days, delete everything older |
| `TENANT` | *(empty)* | `X-Scope-OrgID`; leave empty if `auth_enabled: false` |
| `SVC` | `svc/loki-backend` | Service running the compactor (`svc/loki-compactor` in distributed mode) |
| `NS` | `monitoring` | Namespace of the Loki release |
| `START` | `2020-01-01T00:00:00Z` | Start of the window; must be earlier than your oldest logs |
| `PORT` | `3100` | Local port for the port-forward |

## Before the first real run

- **Check the volume.** Run `sum(count_over_time({retention_policy="Inf"}[1d]))` over the range
  in Grafana, so you know what's about to be deleted.
- **Rehearse in dev.** Submit a request, confirm it shows as `received`, cancel it (below), and
  confirm it disappears.

## Cancelling (wrong cluster, wrong window)

Cancel it before `delete_request_cancel_period` has passed:

```sh
kubectl -n monitoring port-forward svc/loki-backend 3100:3100 &
curl -H 'X-Scope-OrgID: <tenant>' http://localhost:3100/loki/api/v1/delete \
  | jq '.[] | select(.status=="received")'                       # find request_id
curl -X DELETE -H 'X-Scope-OrgID: <tenant>' \
  'http://localhost:3100/loki/api/v1/delete?request_id=<id>'
```

Once the cancel window has passed, use the versioned bucket and restore procedure in
[`../loki-s3-versioning/`](../loki-s3-versioning/) as your fallback.

## Notes

- **A request only covers data that exists when you submit it.** New Inf logs keep
  accumulating, so repeat the cleanup when storage matters.
- **Processed requests stay in Loki's delete request list,** and the API can't remove them.
  One request per run is harmless: the time ranges are always in the past.
- **Deletion is permanent once processed,** unless the bucket is versioned.
