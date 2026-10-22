# Loki retention override (out-of-band, not in the Flux repo)

Adds a higher-priority `retention_stream` rule to the `loki` HelmRelease in the
`monitoring` namespace, setting `{retention_policy="Inf"}` to `30d`, **without
committing anything to the Flux Git repo**.

## How it works

- Loki uses the matching `retention_stream` rule with the highest `priority`.
  The existing rules in Git stay untouched; this appends one more rule with
  `priority: 1000`.
- The rule is added as a JSON patch in `spec.patches` on the **Flux
  Kustomization that applies the HelmRelease**, set only in the cluster.
- It's applied with server-side apply under its own field manager
  (`loki-retention-override`), so Flux doesn't revert it as long as Git doesn't
  set `spec.patches` on that Kustomization.
- Because it only lives in this cluster's API, it can't be merged or promoted
  to another environment.

> ⚠️ `Inf` suggests these logs were meant to be kept forever. Once the
> compactor runs, everything older than 30 days with that label is
> **permanently deleted** (after `retention_delete_delay`, 2h by default).

## 1. Find the Flux Kustomization that applies the HelmRelease

```sh
kubectl -n monitoring get helmrelease loki \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{" "}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/namespace}{"\n"}'
```

```sh
KS_NAME=<name from above>
KS_NS=<namespace from above>   # usually flux-system
```

## 2. Check the list is in `spec.values` and find the highest priority

```sh
kubectl -n monitoring get helmrelease loki \
  -o jsonpath='{.spec.values.loki.limits_config.retention_stream}{"\n"}'
```

- Prints the list → continue.
- Empty → the list lives elsewhere (e.g. `valuesFrom`) and the patch path
  below won't work. Stop and investigate.
- `1000` must be higher than every existing `priority`.

## 3. Make sure Git doesn't set `spec.patches` on that Kustomization

```sh
kubectl -n "$KS_NS" get kustomization "$KS_NAME" -o jsonpath='{.spec.patches}{"\n"}'
```

Must print nothing. If it prints patches, Git owns that list and Flux will
remove yours.

## 4. Apply the override

```sh
kubectl apply --server-side \
  --field-manager=loki-retention-override \
  -f - <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${KS_NAME}
  namespace: ${KS_NS}
  annotations:
    ops/override: "loki retention_policy=Inf -> 30d (applied out-of-band, not in Git)"
spec:
  patches:
    - target:
        kind: HelmRelease
        name: loki
        namespace: monitoring
      patch: |
        - op: add
          path: /spec/values/loki/limits_config/retention_stream/-
          value:
            selector: '{retention_policy="Inf"}'
            priority: 1000
            period: 30d
EOF
```

## 5. Reconcile

```sh
flux reconcile kustomization "$KS_NAME" -n "$KS_NS" --with-source
flux reconcile helmrelease loki -n monitoring
```

## 6. Verify

```sh
# Your rule is the last entry; Git entries unchanged
helm get values loki -n monitoring | grep -A20 retention_stream

# The patch is owned by your field manager
kubectl -n "$KS_NS" get kustomization "$KS_NAME" -o yaml --show-managed-fields \
  | grep -B2 -A8 loki-retention-override

# It survives a second reconcile
flux reconcile kustomization "$KS_NAME" -n "$KS_NS"
helm get values loki -n monitoring | grep -B1 -A2 'retention_policy="Inf"'
```

## Removing the override

Apply the object with no `spec` under the same field manager; server-side
apply drops the fields that manager owned.

```sh
kubectl apply --server-side --field-manager=loki-retention-override -f - <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${KS_NAME}
  namespace: ${KS_NS}
EOF
flux reconcile kustomization "$KS_NAME" -n "$KS_NS"
```

## Failure modes

- **Every failure removes the rule, it never applies by accident.** If Git
  later sets `spec.patches` on the Kustomization, or the Kustomization is
  deleted and recreated, the override disappears and retention falls back to
  the Git rules.
- **Invisible to anyone reading the Flux repo.** The `ops/override`
  annotation is there so the next person knows why Loki's config differs.
