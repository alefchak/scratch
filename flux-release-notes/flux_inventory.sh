#!/usr/bin/env bash
#
# What Flux has deployed right now: Git and OCI repos, Helm charts and container
# images, as Markdown. No snapshots and no comparison with earlier releases.
#
# Needs bash, jq and kubectl.
#
# Usage: flux_inventory.sh [--context NAME] [--kubeconfig FILE] [-n NAMESPACE] [--out FILE]

set -euo pipefail

kc=(kubectl)
where=(-A)
out=/dev/stdout

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)      kc+=(--context "$2"); shift ;;
    --kubeconfig)   kc+=(--kubeconfig "$2"); shift ;;
    -n|--namespace) where=(-n "$2"); shift ;;
    --out)          out="$2"; shift ;;
    -h|--help)      sed -n '3,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A Flux CRD that isn't installed just means there is nothing of that kind.
get() { "${kc[@]}" get "$@" -o json 2>/dev/null || echo '{"items": []}'; }

get gitrepositories.source.toolkit.fluxcd.io -A > "$tmp/git.json"
get ocirepositories.source.toolkit.fluxcd.io -A > "$tmp/oci.json"
get helmreleases.helm.toolkit.fluxcd.io -A      > "$tmp/helm.json"
"${kc[@]}" get deployments,statefulsets,daemonsets,cronjobs "${where[@]}" -o json > "$tmp/workloads.json"
"${kc[@]}" get pods "${where[@]}" -o json > "$tmp/pods.json"

context=$("${kc[@]}" config current-context 2>/dev/null || echo unknown)
k8s=$("${kc[@]}" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion') || k8s=unknown
flux=$("${kc[@]}" get namespace flux-system -o json 2>/dev/null |
  jq -r '.metadata.labels["app.kubernetes.io/version"] // "unknown"') || flux=unknown

{
  echo "# Deployed versions"
  echo
  echo "\`$context\` · Kubernetes $k8s · Flux $flux · $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo

  # Repos: a revision like "main@sha1:abc..." or "v1.2.0@sha256:abc..." gives the
  # version and the commit/digest. Tokens in https URLs (https://user:token@host/...)
  # are removed.
  echo "## Repositories"
  echo
  echo "| Repository | URL | Version | Commit / digest |"
  echo "|---|---|---|---|"
  jq -rs '
    [.[].items[]] | sort_by(.metadata.name)[]
    | (.status.artifact.revision // "" | capture("^((?<version>.*)[@/])?(?<hash>[^@/]*)$")) as $rev
    | ($rev.version // "" | sub("^refs/(heads|tags)/"; "") | if . == "" then "-" else . end) as $version
    | ($rev.hash | split(":") | last // "-" | .[:12]) as $hash
    | (.spec.url | sub("^(?<scheme>https?|oci)://[^/]*@"; "\(.scheme)://")) as $url
    | "| \(.metadata.namespace)/\(.metadata.name) | \($url) | `\($version)` | `\($hash)` |"
  ' "$tmp/git.json" "$tmp/oci.json"
  echo

  # Helm charts: status.history[0] is what Helm actually installed.
  echo "## Helm charts"
  echo
  echo "| HelmRelease | Chart | Version | App version |"
  echo "|---|---|---|---|"
  jq -r '
    .items | sort_by(.metadata.namespace, .metadata.name)[]
    | (.status.history // [])[0] as $h
    | "| \(.metadata.namespace)/\(.metadata.name) | \($h.chartName // .spec.chart.spec.chart // "-") | `\($h.chartVersion // .status.lastAppliedRevision // "-")` | `\($h.appVersion // "-")` |"
  ' "$tmp/helm.json"
  echo

  # Images: every container in a workload that Flux applied (it carries a Flux label).
  # The digest comes from the pods running that image, or from the image reference
  # itself if it is pinned. A workload with no pods (scaled to zero, an idle
  # CronJob) has no digest unless it is pinned.
  echo "## Images"
  echo
  echo "| Image | Tag | Digest | Used by |"
  echo "|---|---|---|---|"
  jq -rn --slurpfile workloads "$tmp/workloads.json" --slurpfile pods "$tmp/pods.json" '
    def containers: (.initContainers // []) + .containers | .[];

    # image (as written in the pod spec) -> digests the pods are running
    ([ $pods[0].items[]
       | ((.status.initContainerStatuses // []) + (.status.containerStatuses // [])) as $status
       | .spec | containers | .name as $name | .image as $image
       | $status[] | select(.name == $name and (.imageID | contains("@")))
       | {image: $image, digest: (.imageID | split("@")[1])} ]
     | group_by(.image) | map({key: .[0].image, value: (map(.digest) | unique)}) | from_entries
    ) as $running

    | [ $workloads[0].items[]
        | select(.metadata.labels // {} | has("kustomize.toolkit.fluxcd.io/name") or has("helm.toolkit.fluxcd.io/name"))
        | "\(.metadata.namespace)/\(.metadata.name)" as $workload
        | (if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end)
        | containers
        | {image, workload: $workload} ]
    | group_by(.image)[]
    | .[0].image as $image
    | ($image | split("@")) as [$ref, $pinned]
    | ($ref | if (split("/") | last | contains(":")) then capture("^(?<name>.*):(?<tag>[^:]*)$") else {name: ., tag: (if $pinned then "-" else "latest" end)} end) as $parts
    | (if $pinned then [$pinned] else $running[$image] // [] end) as $digests
    | ([.[].workload] | unique | join(", ")) as $used_by
    | "| `\($parts.name)` | `\($parts.tag)` | \(if $digests == [] then "unknown" else $digests | map("`\(.)`") | join("<br>") end) | \($used_by) |"
  ' | sort
  echo
} > "$out"
