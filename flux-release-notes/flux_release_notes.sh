#!/usr/bin/env bash
#
# Release notes for a Kubernetes cluster deployed by Flux.
#
# Everything is read from the cluster, never from Git: Flux sources, Kustomizations,
# HelmReleases and every container image. Each image is traced back to the repo
# that delivered it. The output is Markdown plus a JSON snapshot; pass last
# release's snapshot with --previous to get a "What changed" section.
#
# Needs bash 4+, jq 1.6+ and kubectl. crane or skopeo are optional (--resolve-digests).
# See README.md for details.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: flux_release_notes.sh [options]

  --context NAME           kubectl context
  --kubeconfig FILE        kubeconfig file
  -n, --namespace NS       only look at workloads in this namespace
  --exclude-namespace NS   skip a namespace (repeatable, default: the kube-* ones)
  --include-unmanaged      also list workloads that Flux didn't apply
  --flux-namespace NS      where Flux is installed (default: flux-system)
  --resolve-digests MODE   off (default), auto, crane or skopeo
  --forge HOST=TYPE        self-hosted git server: github, gitlab or bitbucket

  --release NAME           name of this release, saved in the snapshot
  --previous FILE          last release's snapshot, to compare with
  --title TEXT             heading for the notes

  --format FORMAT          summary (default), inventory or detailed
  --out FILE               where to write the notes (default: stdout)
  --inventory-out FILE     also write the inventory here
  --detailed-out FILE      also write the detailed report here
  --snapshot-out FILE      write the JSON snapshot here
  --images-out FILE        write the list of unique images here
EOF
}

context="" kubeconfig="" namespace="" flux_ns="flux-system" resolve="off"
include_unmanaged=false release="" previous="" title="" format="summary"
out="" inventory_out="" detailed_out="" snapshot_out="" images_out=""
excluded=()
forges='{}'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)           context="$2"; shift ;;
    --kubeconfig)        kubeconfig="$2"; shift ;;
    -n|--namespace)      namespace="$2"; shift ;;
    --exclude-namespace) excluded+=("$2"); shift ;;
    --include-unmanaged) include_unmanaged=true ;;
    --flux-namespace)    flux_ns="$2"; shift ;;
    --resolve-digests)   resolve="$2"; shift ;;
    --forge)
      host="${2%%=*}" type="${2#*=}"
      if [[ ! $type =~ ^(github|gitlab|bitbucket)$ ]]; then
        echo "--forge $2: type must be github, gitlab or bitbucket" >&2; exit 2
      fi
      forges=$(jq -c --arg h "$host" --arg t "$type" '.[$h] = $t' <<<"$forges")
      shift ;;
    --release)           release="$2"; shift ;;
    --previous)          previous="$2"; shift ;;
    --title)             title="$2"; shift ;;
    --format)            format="$2"; shift ;;
    --out)               out="$2"; shift ;;
    --inventory-out)     inventory_out="$2"; shift ;;
    --detailed-out)      detailed_out="$2"; shift ;;
    --snapshot-out)      snapshot_out="$2"; shift ;;
    --images-out)        images_out="$2"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$format" in
  summary|inventory|detailed) ;;
  *) echo "--format must be summary, inventory or detailed" >&2; exit 2 ;;
esac

if [[ ${#excluded[@]} -eq 0 ]]; then
  excluded=(kube-system kube-public kube-node-lease)
fi

resolver=""
case "$resolve" in
  off) ;;
  crane|skopeo)
    command -v "$resolve" >/dev/null || { echo "--resolve-digests: $resolve is not installed" >&2; exit 1; }
    resolver="$resolve" ;;
  auto)
    if command -v crane >/dev/null; then resolver=crane
    elif command -v skopeo >/dev/null; then resolver=skopeo
    else echo "warning: neither crane nor skopeo is installed, skipping registry lookups" >&2
    fi ;;
  *) echo "--resolve-digests must be off, auto, crane or skopeo" >&2; exit 2 ;;
esac

kc=(kubectl)
[[ -n $kubeconfig ]] && kc+=(--kubeconfig "$kubeconfig")
[[ -n $context ]] && kc+=(--context "$context")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------------
# jq functions shared by every step below
# --------------------------------------------------------------------------------
lib='
# Objects are referred to as "Kind|namespace|name".
def key($kind): "\($kind)|\(.metadata.namespace)|\(.metadata.name)";
def pretty: if . == "" then "" else split("|") | "\(.[0]) \(.[1])/\(.[2])" end;
def nonempty: select(. != null and . != "");

# The HelmRelease or Kustomization that applied an object, from its labels.
def flux_owner:
  (. // {}) as $l
  | if ($l["helm.toolkit.fluxcd.io/name"] // "") != "" then
      "HelmRelease|\($l["helm.toolkit.fluxcd.io/namespace"] // "")|\($l["helm.toolkit.fluxcd.io/name"])"
    elif ($l["kustomize.toolkit.fluxcd.io/name"] // "") != "" then
      "Kustomization|\($l["kustomize.toolkit.fluxcd.io/namespace"] // "")|\($l["kustomize.toolkit.fluxcd.io/name"])"
    else "" end;

# Walk up from a HelmRelease/Kustomization to the root Kustomization.
def flux_path($flux): [limit(20; recurse($flux[.].parent // "" | nonempty))];

# The repo that delivered something: the source of the nearest Kustomization above it
# (or the HelmRelease chart source if no Kustomization applied it).
def delivered_by($flux):
  flux_path($flux) as $path
  | ([$path[] | select(startswith("Kustomization|") and $flux[.] != null) | $flux[.].source] | first)
    // ($flux[.].source // "");

# Flux revisions: "main@sha1:abc", "v1.2@sha1:abc", "sha256:abc" or the old "main/abc".
def split_revision:
  if test("^(.*@)?(sha1|sha256|sha384|sha512):[0-9a-f]+$") then
    capture("^((?<ref>.*)@)?(?<hash>(sha1|sha256|sha384|sha512):[0-9a-f]+)$") | [.ref // "", .hash]
  elif test("/[0-9a-f]{40}$") then
    capture("^(?<ref>.*)/(?<hash>[0-9a-f]{40})$") | [.ref, "sha1:\(.hash)"]
  else [., ""] end;
def bare: sub("^[a-z0-9]+:"; "");                      # "sha1:abc" -> "abc"
def short_version:                                     # -> "v1.2 (abc1234)"
  split_revision as [$ref, $hash]
  | [($ref | sub("^refs/(tags|heads)/"; "") | nonempty), ($hash | bare | .[:7] | nonempty)]
  | if length == 2 then "\(.[0]) (\(.[1]))" else .[0] // "-" end;

# Drop credentials from URLs like https://oauth2:TOKEN@host/repo (ssh keeps its user).
def clean_url:
  if test("^(https?|oci|s3|gs)://") then sub("^(?<s>[a-z0-9]+://)[^/]*@"; "\(.s)")
  else sub("^(?<s>[a-z0-9+]+://)(?<u>[^:/@]*):[^/@]*@"; "\(.s)\(.u)@") end;

# "redis:7" -> docker.io / library/redis / 7, the way container runtimes read it.
def parse_image:
  gsub("^\\s+|\\s+$"; "")
  | (if contains("@") then split("@") | {ref: .[0], digest: .[1]} else {ref: ., digest: ""} end) as $x
  | ($x.ref | if (split("/") | last // "" | contains(":")) then capture("^(?<name>.*):(?<tag>[^:]*)$")
              else {name: ., tag: ""} end) as $y
  | ($y.name | split("/")) as $parts
  | if ($parts | length) > 1 and ($parts[0] | test("[.:]") or . == "localhost") then
      {registry: $parts[0], repository: ($parts[1:] | join("/"))}
    else {registry: "docker.io", repository: $y.name} end
  | if .registry | IN("index.docker.io", "registry-1.docker.io") then .registry = "docker.io" else . end
  | if .registry == "docker.io" and (.repository | contains("/") | not) then .repository = "library/\(.repository)" else . end
  | . + {tag: (if $y.tag == "" and $x.digest == "" then "latest" else $y.tag end), digest: $x.digest};
def image_ref: "\(.registry)/\(.repository)" + (if .tag != "" then ":\(.tag)" else "" end);
def full_ref: image_ref + (if .digest != "" then "@\(.digest)" else "" end);
def tag_or_digest: if .tag != "" then .tag elif .digest != "" then .digest[7:14] else "-" end;

# An image with no digest from the manifest or from pods: worth asking the registry.
def needs_lookup:
  .digest == "" and (.spec_image as $img | [.running[] | select(.image == $img and .digest != "")] | length == 0);

# Markdown
def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
def code: if (. // "") == "" then "-" else "`\(esc)`" end;
def fmt_ref: to_entries | map("\(.key) `\(.value)`") | join(", ") | if . == "" then "default" else . end;

# Git URLs to web links. ssh://git@host/x.git and git@host:x.git -> https://host/x
def web_url:
  sub("^ssh://([^@/]+@)?(?<h>[^/:]+)(:[0-9]+)?/"; "https://\(.h)/")
  | sub("^[^@/:]+@(?<h>[^:/]+):"; "https://\(.h)/")
  | sub("\\.git/?$"; "");
def forge($forges):
  ((capture("^https://(?<h>[^/:]+)") | .h) // "") as $host
  | $forges[$host] // ([("github", "gitlab", "bitbucket") | select(. as $f | $host | contains($f))] | first) // "";
def commit_link($url; $sha; $forges):
  ($url | web_url) as $base
  | ($base | forge($forges)) as $forge
  | if $sha == "" then "-"
    elif $forge == "" then $sha[:12] | code
    else "[`\($sha[:12])`](\($base)/\({github: "commit", gitlab: "-/commit", bitbucket: "commits"}[$forge])/\($sha))" end;
def compare_link($url; $old; $new; $forges):
  ($url | web_url) as $base
  | {github: "[compare](\($base)/compare/\($old)...\($new))",
     gitlab: "[compare](\($base)/-/compare/\($old)...\($new))",
     bitbucket: "[compare](\($base)/branches/compare/\($new)%0D\($old))"}[$base | forge($forges)] // "";

# Short name for a source: the repo path from its URL ("acme/team-a").
def repo_label($sources):
  if . == "" then "Not managed by Flux"
  else (($sources[.].url // "") | web_url | sub("[?#].*"; "") | sub("^[a-z]+://[^/]*"; "") | gsub("^/+|/+$"; "")) as $path
    | if $path == "" then pretty else $path end end;

# Everything someone should look at, as [subject, message] pairs.
def warnings:
  .sources as $sources
  | def problem: if .suspended then "suspended"
                 elif .ready != "True" then "not ready: \((.message | nonempty) // .ready)"
                 else empty end;
  [ (.sources | to_entries[] | select(.value.ready != "True")
     | [(.key | pretty), "not ready: \((.value.message | nonempty) // .value.ready)"]),
    (.kustomizations + .helmreleases | to_entries | sort_by(.key)[]
     | (.value | problem) as $problem | [(.key | pretty), $problem]),
    (.kustomizations | to_entries[] | .value as $ks | $sources[$ks.source] as $src
     | select($src != null and $src.revision != "" and $ks.applied_revision != "" and $src.revision != $ks.applied_revision)
     | [(.key | pretty), "behind its source: applied \($ks.applied_revision | short_version), source is at \($src.revision | short_version)"]),
    (.images[] | . as $img | .warnings[]
     | ["\($img.namespace)/\($img.name)" + (if $img.container == $img.name then "" else " (\($img.container))" end), .])
  ];

# Image changes between two snapshots, matched by workload and container.
def image_changes($old; $new):
  def id: "\(.namespace)/\(.kind)/\(.name)/\(.container)";
  INDEX($old[]; id) as $before
  | INDEX($new[]; id) as $after
  | ($before + $after | keys[]) as $k
  | {a: $before[$k], b: $after[$k]}
  | if .a == null then .change = "Added"
    elif .b == null then .change = "Removed"
    elif (.a | image_ref) != (.b | image_ref) or (.a.digest != "" and .b.digest != "" and .a.digest != .b.digest)
      then .change = "Updated"
    else empty end;
'

# --------------------------------------------------------------------------------
# Read the cluster
# --------------------------------------------------------------------------------
# A Flux CRD that isn't installed (no Buckets, say) just means there are none.
flux_list() {
  "${kc[@]}" get "$1" -A -o json 2>/dev/null || echo '{"items": []}'
}
flux_list gitrepositories.source.toolkit.fluxcd.io    >"$tmp/git.json"
flux_list ocirepositories.source.toolkit.fluxcd.io    >"$tmp/oci.json"
flux_list buckets.source.toolkit.fluxcd.io            >"$tmp/buckets.json"
flux_list helmrepositories.source.toolkit.fluxcd.io   >"$tmp/helmrepos.json"
flux_list kustomizations.kustomize.toolkit.fluxcd.io  >"$tmp/kustomizations.json"
flux_list helmreleases.helm.toolkit.fluxcd.io         >"$tmp/helmreleases.json"

if [[ -n $namespace ]]; then where=(-n "$namespace"); else where=(-A); fi
"${kc[@]}" get deployments,statefulsets,daemonsets,cronjobs,jobs,replicasets "${where[@]}" -o json >"$tmp/workloads.json"
"${kc[@]}" get pods "${where[@]}" -o json >"$tmp/pods.json"

cluster_context=${context:-$("${kc[@]}" config current-context 2>/dev/null || echo unknown)}
k8s_version=$("${kc[@]}" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"') || k8s_version=unknown
flux_version=$("${kc[@]}" get namespace "$flux_ns" -o json 2>/dev/null |
  jq -r '.metadata.labels["app.kubernetes.io/version"] // "unknown"') || flux_version=unknown

excluded_json=$(printf '%s\n' "${excluded[@]}" | jq -R . | jq -sc .)
jq -s --argjson excluded "$excluded_json" \
  '[.[].items[] | select(.metadata.namespace | IN($excluded[]) | not)]' \
  "$tmp/workloads.json" "$tmp/pods.json" >"$tmp/objects.json"

# Pods and workloads can be owned by things we didn't list, like an operator's custom
# resource (a CNPG Cluster, an Argo Rollout). Fetch those one at a time so we can read
# their Flux labels. If we can't read one, add a stub so it still shows up by name.
while true; do
  jq -r 'INDEX(.metadata.uid) as $known
    | .[] | .metadata.namespace as $ns
    | (.metadata.ownerReferences // [] | (map(select(.controller)) + .) | first) // empty
    | select(.kind != "Node" and $known[.uid] == null)
    | [$ns, .kind, .apiVersion, .name, .uid] | @tsv' "$tmp/objects.json" | sort -u >"$tmp/missing.tsv"
  [[ -s $tmp/missing.tsv ]] || break

  while IFS=$'\t' read -r ns kind api name uid; do
    resource=${kind,,}
    [[ $api == */* ]] && resource+=".${api%%/*}"
    if ! "${kc[@]}" get "$resource" "$name" -n "$ns" -o json >"$tmp/owner.json" 2>/dev/null; then
      jq -n --arg k "$kind" --arg n "$name" --arg ns "$ns" '{kind: $k, metadata: {name: $n, namespace: $ns}}' >"$tmp/owner.json"
    fi
    jq --slurpfile owner "$tmp/owner.json" --arg uid "$uid" \
      '. + [$owner[0] | .kind //= "?" | .metadata.uid = $uid]' "$tmp/objects.json" >"$tmp/objects.new"
    mv "$tmp/objects.new" "$tmp/objects.json"
  done <"$tmp/missing.tsv"
done

# --------------------------------------------------------------------------------
# Previous snapshot
# --------------------------------------------------------------------------------
echo null >"$tmp/previous.json"
if [[ -n $previous ]]; then
  if [[ $(jq '.schema' "$previous") == 2 ]]; then
    cp "$previous" "$tmp/previous.json"
  else
    echo "warning: $previous is an older snapshot format, skipping the comparison" >&2
  fi
fi

# --------------------------------------------------------------------------------
# Flux objects
# --------------------------------------------------------------------------------
jq -n -S "$lib"'
  def ready_status:
    ([.status.conditions // [] | .[] | select(.type == "Ready")] | first) as $c
    | {ready: ($c.status // "Unknown"),
       message: (if ($c.status // "") == "True" then "" else $c.message // "" | gsub("^\\s+|\\s+$"; "") end)};

  def ref_key($ns): if (.kind // "") == "" then "" else "\(.kind)|\(.namespace // $ns)|\(.name)" end;

  def source($kind):
    (.status.artifact.revision // "") as $rev
    | {key: key($kind), value: ({
        kind: $kind,
        url: (if $kind == "Bucket" then "\(.spec.endpoint // "")/\(.spec.bucketName // "")" else .spec.url // "" end | clean_url),
        ref: (.spec.ref // {} | with_entries(select(.value | type == "string" and . != ""))),
        type: (.spec.type // ""),
        revision: $rev,
        resolved_ref: ($rev | split_revision | .[0]),
        hash: ($rev | split_revision | .[1]),
        suspended: (.spec.suspend == true)
      } + ready_status)};

  def kustomization:
    .metadata.namespace as $ns
    | {key: key("Kustomization"), value: ({
        parent: (.metadata.labels | flux_owner),
        source: (.spec.sourceRef | ref_key($ns)),
        path: (.spec.path | nonempty // "./"),
        applied_revision: (.status.lastAppliedRevision // ""),
        attempted_revision: (.status.lastAttemptedRevision // ""),
        suspended: (.spec.suspend == true)
      } + ready_status)};

  def helmrelease:
    .metadata as $md
    | (.spec // {}) as $spec
    | (.status.history // [])[0] as $last     # what Helm actually installed
    | $spec.chart.spec as $chart              # null when the chart comes from spec.chartRef
    | (if $chart then $chart.sourceRef else $spec.chartRef end | ref_key($md.namespace)) as $source
    | ($chart.chart // "") as $chart_name
    | {key: key("HelmRelease"), value: ({
        parent: ($md.labels | flux_owner),
        source: $source,
        chart: ($last.chartName | nonempty // $chart_name),
        chart_path: (if $source | startswith("GitRepository|") then $chart_name else "" end),
        # v2beta1 has no history, but its lastAppliedRevision is the chart version
        chart_version: (if $last then $last.chartVersion // "" else .status.lastAppliedRevision // "" end),
        app_version: ($last.appVersion // ""),
        requested_version: (if $chart then $chart.version | nonempty // "*" else "" end),
        chart_digest: ($last.ociDigest // ""),
        release_name: (($last.name | nonempty) // ($spec.releaseName | nonempty)
                       // (if ($spec.targetNamespace // "") != "" then "\($spec.targetNamespace)-\($md.name)" else $md.name end)),
        target_namespace: ($spec.targetNamespace | nonempty // $md.namespace),
        helm_status: ($last.status // ""),
        deployed_at: ($last.lastDeployed // ""),
        attempted_revision: (.status.lastAttemptedRevision // ""),
        suspended: ($spec.suspend == true)
      } + ready_status)};

  {
    schema: 2,
    release: $release,
    previous_release: ($previous[0].release // ""),
    context: $context,
    kubernetes_version: $k8s_version,
    flux_version: $flux_version,
    generated_at: (now | strftime("%Y-%m-%d %H:%M:%S UTC")),
    sources: ([ ($git[0].items[] | source("GitRepository")),
                ($oci[0].items[] | source("OCIRepository")),
                ($buckets[0].items[] | source("Bucket")),
                ($helmrepos[0].items[] | source("HelmRepository")) ] | from_entries),
    kustomizations: ([$kustomizations[0].items[] | kustomization] | from_entries),
    helmreleases: ([$helmreleases[0].items[] | helmrelease] | from_entries)
  }' \
  --arg release "$release" --arg context "$cluster_context" \
  --arg k8s_version "$k8s_version" --arg flux_version "$flux_version" \
  --slurpfile previous "$tmp/previous.json" \
  --slurpfile git "$tmp/git.json" --slurpfile oci "$tmp/oci.json" \
  --slurpfile buckets "$tmp/buckets.json" --slurpfile helmrepos "$tmp/helmrepos.json" \
  --slurpfile kustomizations "$tmp/kustomizations.json" --slurpfile helmreleases "$tmp/helmreleases.json" \
  >"$tmp/flux.json"

# --------------------------------------------------------------------------------
# Images
# --------------------------------------------------------------------------------
# One entry per workload container. Pod templates give the image we asked for (and
# cover idle CronJobs and deployments scaled to zero); pods give the digest that is
# actually running (and cover pods that operators create).
jq -S --slurpfile snap "$tmp/flux.json" --argjson unmanaged "$include_unmanaged" "$lib"'
  ($snap[0].kustomizations + $snap[0].helmreleases) as $flux
  | INDEX(.metadata.uid) as $by_uid

  | def owner:
      (.metadata.ownerReferences // [] | (map(select(.controller)) + .) | first) // empty
      | select(.kind != "Node") | $by_uid[.uid] // empty;
    # The object, its owner, its owner'"'"'s owner, ...
    def chain: [limit(20; recurse(owner))];
    # The thing a person manages: skip Pods, ReplicaSets and Jobs that something owns.
    def workload: ([.[] | select(.kind | IN("Pod", "ReplicaSet", "Job") | not)] | first) // last;

    def pod_template:
      if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end // {};
    def containers:
      ((.initContainers // [])[] | {name, image, type: (if .restartPolicy == "Always" then "sidecar" else "init" end)}),
      ((.containers // [])[] | {name, image, type: "container"});

    # containerStatus.imageID: "docker-pullable://repo@sha256:..." has the registry digest,
    # a bare "sha256:..." is only the local image ID (not something you can pull).
    def image_id:
      sub("^[a-z-]+://"; "")
      | if contains("@") then {digest: sub("^[^@]*@"; ""), image_id: ""}
        elif startswith("sha256:") then {digest: "", image_id: .}
        else {digest: "", image_id: ""} end;

    def settle_digest:
      .spec_image as $img
      | [.running[] | select(.image == $img)] as $now
      | [.running[] | select(.image != $img)] as $old
      | ([$now[].digest | nonempty] | unique) as $seen
      | . + ($img | parse_image) + {digest_source: "", pods: ([$now[].pods] | add // 0), warnings: []}
      | .digest as $pinned
      | if $pinned != "" then
          .digest_source = "pinned"
          | if any($seen[]; . != $pinned) then .warnings += ["running digest differs from the pinned digest"] else . end
        elif ($seen | length) == 1 then
          .digest = $seen[0] | .digest_source = "running pods"
        elif ($seen | length) > 1 then
          .warnings += ["tag was re-pushed; pods run \($seen | length) different digests (\($seen | map(.[7:19]) | join(", ")))"]
        elif any($now[]; .image_id != "") then
          .warnings += ["node reported no registry digest"]
        else . end
      | if .digest == "" and .warnings == [] then
          .warnings += ["digest unknown" + (if .running == [] then " (no pods running)" else "" end)]
        else . end
      | if $old != [] then
          ([$old[].pods] | add) as $n
          | .warnings += ["rollout in progress: \($n) pod\(if $n == 1 then "" else "s" end) still on \([$old[].image] | unique | join(", "))"]
        else . end
      | .image = full_ref;

  [ .[] | . as $obj
    | chain as $chain
    | ($chain | workload) as $w
    | { namespace: $w.metadata.namespace, kind: $w.kind, name: $w.metadata.name,
        controlled_by: (if $w.metadata.uid != $chain[-1].metadata.uid then "\($chain[-1].kind)/\($chain[-1].metadata.name)" else "" end),
        owner: ([$chain[].metadata.labels | flux_owner | nonempty] | last // "") }
    | if $obj.kind == "Pod" then
        ([($obj.status.initContainerStatuses // [])[], ($obj.status.containerStatuses // [])[]] | INDEX(.name)) as $status
        | ($obj.spec | containers) as $c
        | . + {container: $c.name, container_type: $c.type, spec_image: $c.image,
               running: ({image: $c.image} + ($status[$c.name].imageID // "" | image_id))}
      elif $w.metadata.uid == $obj.metadata.uid
           and ($obj.kind | IN("Deployment", "StatefulSet", "DaemonSet", "CronJob", "Job", "ReplicaSet")) then
        ($obj | pod_template | containers) as $c
        | . + {container: $c.name, container_type: $c.type, spec_image: $c.image, running: null}
      else empty end
  ]
  | map(select(.owner != "" or $unmanaged))
  | group_by([.namespace, .kind, .name, .container])
  | map(
      # the template (if there is one) says which image we want; pods say what runs
      sort_by(.running != null) as $rows
      | $rows[0]
      | .running = ([$rows[].running | select(. != null)] | group_by(.) | map(.[0] + {pods: length}) | sort_by([.image, .digest, .image_id]))
      | if .owner == "" then .source = "" | .chain = []
        else .source = (.owner | delivered_by($flux)) | .chain = (.owner | flux_path($flux) | reverse) end
      | settle_digest)
  | sort_by([(.source == ""), .source, .owner, .namespace, .kind, .name, .container])
' "$tmp/objects.json" >"$tmp/images.json"

# Ask the registry for digests that neither the manifest nor any pod gave us.
registry_digest() {
  case "$resolver" in
    crane)  timeout 90 crane digest "$1" </dev/null ;;
    skopeo) timeout 90 skopeo inspect --raw "docker://$1" </dev/null | sha256sum | sed 's/^/sha256:/; s/ .*//' ;;
  esac
}

if [[ -n $resolver ]]; then
  echo '{}' >"$tmp/digests.json"
  jq -r "$lib"'.[] | select(needs_lookup) | .image' "$tmp/images.json" | sort -u >"$tmp/lookups.txt"
  while read -r ref; do
    if digest=$(registry_digest "$ref" 2>"$tmp/err"); then
      error=""
    else
      [[ $? == 124 ]] && echo "registry lookup timed out" >"$tmp/err"
      digest=""
      error=$(sed '/^[[:space:]]*$/d' "$tmp/err" | tail -n 1)
    fi
    jq --arg ref "$ref" --arg digest "$digest" --arg error "${error:-lookup failed}" \
      '.[$ref] = {digest: $digest, error: $error}' "$tmp/digests.json" >"$tmp/digests.new"
    mv "$tmp/digests.new" "$tmp/digests.json"
  done <"$tmp/lookups.txt"

  jq -S --slurpfile digests "$tmp/digests.json" "$lib"'
    map(if needs_lookup and $digests[0][.image] then
          $digests[0][.image] as $found
          | .warnings |= map(select(startswith("digest unknown") | not))
          | if $found.digest != "" then
              .digest = $found.digest | .digest_source = "registry" | .image = full_ref
            else
              .warnings += ["registry lookup failed: \($found.error)"]
            end
        else . end)' "$tmp/images.json" >"$tmp/images.new"
  mv "$tmp/images.new" "$tmp/images.json"
fi

jq -S --slurpfile images "$tmp/images.json" '.images = $images[0]' "$tmp/flux.json" >"$tmp/snapshot.json"

# --------------------------------------------------------------------------------
# Markdown
# --------------------------------------------------------------------------------
# render [jq args] PROGRAM: run a jq program on the snapshot and print its lines.
# $prev is the previous snapshot (or null), $forges and $title come from the options.
render() {
  local program="${*: -1}"
  jq -r "${@:1:$#-1}" --slurpfile previous "$tmp/previous.json" --argjson forges "$forges" \
    --arg title "$title" "$lib"' $previous[0] as $prev | '"$program" "$tmp/snapshot.json"
}

header() {  # header DEFAULT_HEADING SHOW_COMPARISON(true|false)
  render --arg default "$1" --argjson compare "$2" '
    (if $title != "" then $title elif .release != "" then "Release \(.release)" else $default end) as $heading
    | "# \($heading | esc)",
      "",
      ([ "`\(.context)`", "Kubernetes \(.kubernetes_version)", "Flux \(.flux_version)", "\(.generated_at[:16]) UTC" ]
       + (if $prev and $compare then ["compared with \($prev.release | nonempty // $prev.generated_at[:16])"] else [] end)
       | join(" · ")),
      ""'
}

what_changed() {
  render '
    if $prev == null then empty else
    . as $now
    | ($prev.sources + .sources) as $sources
    | [
        # repos that moved to a new commit, tag or URL
        ($sources | keys[] as $k | {a: $prev.sources[$k], b: $now.sources[$k]}
         | select((.a // .b).kind != "HelmRepository")
         | if .a == null then {repo: $k, head: "new source"}
           elif .b == null then {repo: $k, head: "source removed"}
           elif [.a.url, .a.ref, .a.hash] == [.b.url, .b.ref, .b.hash] then empty
           else
             (if .b.kind == "GitRepository" then compare_link(.b.url; .a.hash | bare; .b.hash | bare; $forges) else "" end) as $link
             | {repo: $k, head: ("\(.a.revision | short_version) → \(.b.revision | short_version)" + (if $link != "" then " (\($link))" else "" end))}
           end),

        # Helm charts, under the repo that deploys them
        ($prev.helmreleases + $now.helmreleases | keys[] as $k | {a: $prev.helmreleases[$k], b: $now.helmreleases[$k]}
         | select(.a == null or .b == null or [.a.chart, .a.chart_version, .a.chart_digest] != [.b.chart, .b.chart_version, .b.chart_digest])
         | (.b // .a).chart as $chart
         | ($k | split("|") | .[2]) as $name
         | (if .a == null then "added, \(.b.chart_version)" elif .b == null then "removed"
            else "\(.a.chart_version) → \(.b.chart_version)" end) as $change
         | (if .b then $now else $prev end | .kustomizations + .helmreleases) as $flux
         | {repo: ($k | delivered_by($flux)),
            line: "Chart `\($chart | esc)`\(if $name == $chart then "" else " (\($name | esc))" end): \($change)"}),

        # images, under the repo that delivers them
        (image_changes($prev.images; $now.images)
         | (.b // .a) as $e
         | ($e.repository | split("/") | .[-2:] | join("/") | esc) as $short
         | (if ($e.repository | split("/") | last) == $e.name then "" else " in \($e.name | esc)" end) as $where
         | {repo: $e.source, line: (
             if .change == "Added" then "`\($short):\(.b | tag_or_digest)` added\($where)"
             elif .change == "Removed" then "`\($short)` removed\($where)"
             elif (.a | image_ref) == (.b | image_ref) then
               "`\($short)` \(.b | tag_or_digest) re-pushed\($where) (digest \(.a.digest[7:14]) → \(.b.digest[7:14]))"
             elif [.a.registry, .a.repository] == [.b.registry, .b.repository] then
               "`\($short)` \(.a | tag_or_digest) → \(.b | tag_or_digest)\($where)"
             else "`\(.a | image_ref)` → `\(.b | image_ref)`\($where)" end)})
      ]
    | group_by(.repo)
    | sort_by([(.[0].repo == ""), (.[0].repo | repo_label($sources))])
    | "## What changed",
      "",
      (if . == [] then "Nothing changed since the last release.", "" else empty end),
      (.[]
       | ([.[].head | nonempty] | first) as $head
       | "**\(.[0].repo | repo_label($sources) | esc)**" + (if $head then " — \($head)" else "" end),
         (.[].line | nonempty | "- \(.)"),
         "")
    end'
}

needs_attention() {
  render '
    # one line per subject, at most ten
    (reduce (warnings | .[]) as [$subject, $msg] ([];
       if any(.[]; .[0] == $subject) then map(if .[0] == $subject then .[1] += "; \($msg)" else . end)
       else . + [[$subject, $msg]] end)) as $list
    | if $list == [] then empty else
        "## Needs attention",
        "",
        ($list[:10][] | "- **\(.[0] | esc)**: \(.[1] | esc)"),
        (if ($list | length) > 10 then "- …and \(($list | length) - 10) more (see the full report)" else empty end),
        ""
      end'
}

deployed() {  # deployed HEADING_LEVEL
  render --arg h "$1" '
    .sources as $sources
    | [.sources | to_entries[] | select(.value.kind | IN("GitRepository", "OCIRepository", "Bucket"))] as $repos
    | (if $repos == [] then empty else
        "\($h) Repositories", "", "| Repository | Version | Commit / digest |", "|---|---|---|",
        ($repos | sort_by(.key | repo_label($sources))[]
         | .value as $s
         | ($s.revision | split_revision) as [$ref, $hash]
         | (if $s.kind == "GitRepository" then commit_link($s.url; $hash | bare; $forges) else $hash | bare | .[:12] | code end) as $commit
         | "| \(.key | repo_label($sources) | esc) | \($ref | sub("^refs/(tags|heads)/"; "") | code) | \($commit) |"),
        ""
      end),
      (if .helmreleases == {} then empty else
        "\($h) Helm charts", "", "| Helm chart | Release | Version |", "|---|---|---|",
        (.helmreleases | to_entries | sort_by([.value.chart, .key])[] | .value
         | "| \(.chart | code) | \(.target_namespace + "/" + .release_name | esc) | \(.chart_version | code) |"),
        ""
      end),
      (if .images == [] then empty else
        "\($h) Images", "", "| Image | Tag | Digest | Used by |", "|---|---|---|---|",
        (.images | group_by(.image) | sort_by([(.[0] | "\(.registry)/\(.repository)"), .[0].image])[]
         | ([.[].name] | unique) as $names
         | (($names[:3] | join(", ")) + (if ($names | length) > 3 then " +\(($names | length) - 3)" else "" end)) as $used_by
         | .[0]
         | "| \("\(.registry)/\(.repository)" | code) | \(.tag | code) | \(if .digest != "" then .digest | code else "⚠️ unknown" end) | \($used_by | esc) |"),
        ""
      end)'
}

detailed_report() {
  render '
    .sources as $sources | .kustomizations as $ks | .helmreleases as $hrs
    | def of_kind($kind): $sources | to_entries | map(select(.value.kind == $kind));
      def ready_cell: if .suspended then "suspended" else .ready end;
    of_kind("GitRepository") as $git
    | of_kind("OCIRepository") as $oci
    | of_kind("Bucket") as $buckets
    | of_kind("HelmRepository") as $helmrepos

    | "## Inventory",
      "",
      "\($git | length) Git repositories, \($oci | length) OCI repositories, \($ks | length) Kustomizations, \($hrs | length) HelmReleases, \([.images[].image] | unique | length) unique images in \(.images | length) containers",
      "",

      (warnings | if . == [] then empty else
        "## Warnings", "", (.[] | "- **\(.[0] | esc)**: \(.[1] | esc)"), "" end),

      "## Flux sources",
      "",
      (if $git == [] then empty else
        "### Git repositories", "",
        "| GitRepository | URL | Ref (spec) | Resolved | Commit | Ready |", "|---|---|---|---|---|---|",
        ($git[] | .value as $s
         | "| \(.key | pretty | esc) | \($s.url | esc) | \($s.ref | fmt_ref) | \($s.resolved_ref | sub("^refs/(tags|heads)/"; "") | code) | \(commit_link($s.url; $s.hash | bare; $forges)) | \($s.ready) |"),
        "" end),
      (if $oci == [] then empty else
        "### OCI repositories", "",
        "| OCIRepository | URL | Ref (spec) | Resolved | Digest | Ready |", "|---|---|---|---|---|---|",
        ($oci[] | .value as $s
         | "| \(.key | pretty | esc) | \($s.url | esc) | \($s.ref | fmt_ref) | \($s.resolved_ref | code) | \($s.hash | code) | \($s.ready) |"),
        "" end),
      (if $buckets == [] then empty else
        "### Buckets", "", "| Bucket | Location | Revision | Ready |", "|---|---|---|---|",
        ($buckets[] | "| \(.key | pretty | esc) | \(.value.url | esc) | \(.value.revision | code) | \(.value.ready) |"),
        "" end),
      (if $helmrepos == [] then empty else
        "### Helm repositories", "", "| HelmRepository | URL | Type | Ready |", "|---|---|---|---|",
        ($helmrepos[] | "| \(.key | pretty | esc) | \(.value.url | esc) | \(.value.type | nonempty // "default" | esc) | \(.value.ready) |"),
        "" end),

      (if $ks == {} then empty else
        "## Kustomizations", "",
        "| Kustomization | Source | Path | Applied revision | Ready |", "|---|---|---|---|---|",
        ($ks | to_entries[] | .value as $k
         | "| \(.key | pretty | esc) | \($k.source | pretty | esc) | \($k.path | code) | \($k.applied_revision | code) | \($k | ready_cell) |"),
        "" end),

      (if $hrs == {} then empty else
        "## Helm releases", "",
        "| HelmRelease | Release | Chart | Version | App version | Requested | Chart source | Chart digest | Ready |",
        "|---|---|---|---|---|---|---|---|---|",
        ($hrs | to_entries[] | .value as $h
         | (($h.requested_version | nonempty | code) // ($sources[$h.source].ref // empty | fmt_ref) // "-") as $requested
         | (($h.source | pretty | nonempty) // "-") as $label
         | ([$sources[$h.source].url, ($h.chart_path | nonempty | "path `\(.)`")] | map(nonempty) | join(" ")) as $where
         | ($label + (if $where != "" then "<br>\($where)" else "" end)) as $chart_source
         | "| \(.key | pretty | esc) | \($h.target_namespace + "/" + $h.release_name | code) | \($h.chart | code) | \($h.chart_version | code) | \($h.app_version | code) | \($requested) | \($chart_source | esc) | \($h.chart_digest | code) | \($h | ready_cell) |"),
        "" end),

      # images, grouped by the repo that delivers them and then by Flux owner
      "## Images",
      "",
      (.images | group_by(.source) | sort_by([(.[0].source == ""), .[0].source])[]
       | .[0].source as $repo
       | if $repo == "" then "### Not managed by Flux"
         else "### \($repo | pretty | esc)" + (($sources[$repo].url | nonempty | " — \(esc)") // "") end,
         ($sources[$repo] | select(.) | "Ref \(.ref | fmt_ref), revision \(.revision | code)"),
         "",
         (group_by(.owner)[]
          | .[0].owner as $owner
          | "#### \($owner | pretty | esc | nonempty // "No Flux owner")",
            ($hrs[$owner] | select(.) | "Chart \(.chart | code) \(.chart_version | code) (app \(.app_version | code))  "),
            ($ks[$owner] | select(.) | "Path \(.path | code), applied \(.applied_revision | code)  "),
            (.[0].chain | select(length > 1) | "Applied via: " + (map(pretty | esc) | join(" → "))),
            "",
            "| Workload | Container | Image | Digest from | Pods |", "|---|---|---|---|---|",
            (.[]
             | ("\(.namespace | esc)/\(.kind)/\(.name | esc)" + ((.controlled_by | nonempty | "<br>(managed by \(esc))") // "")) as $workload
             | ((.container | esc) + (if .container_type == "container" then "" else " (\(.container_type))" end)) as $container
             | "| \($workload) | \($container) | \(.image | code) | \(.digest_source | nonempty // "⚠️ unknown") | \(.pods) |"),
            "")),

      "## All images",
      "",
      "```",
      ([.images[].image] | unique[]),
      "```"'
}

summary() {
  header "Release notes" true
  what_changed
  needs_attention
  printf '## Deployed\n\n'
  deployed "###"
}

inventory() {
  header "Deployed versions" false
  deployed "##"
}

detailed() {
  header "Release notes" true
  detailed_report
}

# --------------------------------------------------------------------------------
# Write everything out
# --------------------------------------------------------------------------------
[[ -z $snapshot_out ]] || jq -S -a . "$tmp/snapshot.json" >"$snapshot_out"
[[ -z $images_out ]] || jq -r '[.images[].image] | unique[]' "$tmp/snapshot.json" >"$images_out"
[[ -z $inventory_out ]] || inventory >"$inventory_out"
[[ -z $detailed_out ]] || detailed >"$detailed_out"

if [[ -n $out ]]; then
  "$format" >"$out"
else
  "$format"
fi
