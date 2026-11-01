#!/usr/bin/env bash
#
# Generate release notes for a Kubernetes cluster whose workloads are deployed by
# FluxCD, built for multi-repo setups (a root repo that syncs in other teams' repos).
#
# Nothing is read from Git. Everything comes from the cluster, so it works however
# each team lays out its repository.
#
# Recorded for every release
#   * Every container image as a full reference: registry/repository:tag@sha256:digest.
#     The digest comes from the image reference itself (pinned), from what the
#     running pods report, or, with --resolve-digests, from the registry.
#   * Every HelmRelease: chart name, deployed chart version, app version, the
#     version constraint requested, chart source URL and OCI chart digest.
#   * Every Flux source: GitRepository URL, ref (branch/tag/semver/commit), the
#     resolved tag or branch and full commit SHA; OCIRepository URL, tag and digest;
#     Buckets and HelmRepositories.
#   * Every Kustomization: source, path and the revision it last applied.
#
# How workloads are traced to the repo that delivers them
#   Pod --ownerReferences--> ReplicaSet/Job --> Deployment/CronJob/... --> any CR owner
#   workload --Flux labels--> HelmRelease or Kustomization that applied it
#   HelmRelease --labels--> Kustomization that applied it
#   Kustomization --spec.sourceRef--> GitRepository / OCIRepository / Bucket
#   Kustomization --labels--> parent Kustomization ... up to the root
#
# The snapshot JSON (schema 2) is the same format the earlier Python version wrote,
# so existing baselines keep working.
#
# Requirements: bash 4+, jq 1.6+, kubectl with read access to the cluster.
# Optional: `crane` or `skopeo` on PATH for --resolve-digests.

set -Eeuo pipefail
on_error() {
  echo "error: line $2: \"$3\" failed (exit $1). Re-run with --debug for a full trace." >&2
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

SCHEMA=2
TEMPLATE_RESOURCES="deployments,statefulsets,daemonsets,cronjobs,jobs,replicasets"
DEFAULT_EXCLUDED_NAMESPACES=(kube-system kube-public kube-node-lease)

usage() {
  cat <<'EOF'
Usage: flux_release_notes.sh [options]

Generate release notes from a Flux-managed cluster.

Cluster
      --context NAME            kubectl context to use
      --kubeconfig PATH         path to kubeconfig
  -n, --namespace NS            limit workloads to one namespace (default: all)
      --exclude-namespace NS    namespace to skip; repeatable
                                (default: kube-system, kube-public, kube-node-lease)
      --include-unmanaged       also list workloads that no Flux object applied
      --flux-namespace NS       namespace Flux is installed in (default: flux-system)
      --resolve-digests MODE    off (default), auto, crane or skopeo: look up digests in
                                the registry for images no pod reports one for
      --forge HOST=TYPE         treat a self-hosted Git host as github, gitlab or
                                bitbucket for links; repeatable

Release
      --release NAME            name of this release (stored in the snapshot)
      --previous FILE           previous snapshot JSON to diff against
      --title TEXT              heading for the release notes

Output
      --snapshot-out FILE       write this run's snapshot JSON here
      --images-out FILE         write the unique full image references, one per line, here
      --out FILE                write Markdown here (default: stdout)
      --format FORMAT           summary (default): what changed, what needs attention,
                                what is deployed; inventory: only what is deployed now,
                                no comparison; detailed: every source, Kustomization,
                                HelmRelease and container
      --inventory-out FILE      also write the inventory here
      --detailed-out FILE       also write the detailed report here

      --debug                   print every command as it runs
  -h, --help                    show this help
EOF
}

die() { echo "error: $*" >&2; exit 1; }
usage_error() { usage >&2; echo "error: $*" >&2; exit 2; }

# ---------------------------------------------------------------------------- #
# Options
# ---------------------------------------------------------------------------- #
CONTEXT="" KUBECONFIG_PATH="" NAMESPACE="" FLUX_NS="flux-system" RESOLVE="off"
INCLUDE_UNMANAGED=false RELEASE="" PREVIOUS="" SNAPSHOT_OUT="" IMAGES_OUT="" OUT=""
TITLE="" FORMAT="summary" INVENTORY_OUT="" DETAILED_OUT=""
EXCLUDED=() EXCLUDE_SET=false FORGES=()

while [[ $# -gt 0 ]]; do
  opt="$1"
  if [[ "$opt" == --*=* ]]; then  # --opt=value
    set -- "${opt%%=*}" "${opt#*=}" "${@:2}"
    opt="$1"
  fi
  case "$opt" in
    --include-unmanaged|--debug|-h|--help) ;;
    *) [[ $# -ge 2 ]] || usage_error "$opt: expected a value" ;;
  esac
  case "$opt" in
    --context)            CONTEXT="$2"; shift 2 ;;
    --kubeconfig)         KUBECONFIG_PATH="$2"; shift 2 ;;
    -n|--namespace)       NAMESPACE="$2"; shift 2 ;;
    --exclude-namespace)  EXCLUDED+=("$2"); EXCLUDE_SET=true; shift 2 ;;
    --include-unmanaged)  INCLUDE_UNMANAGED=true; shift ;;
    --flux-namespace)     FLUX_NS="$2"; shift 2 ;;
    --resolve-digests)    RESOLVE="$2"; shift 2 ;;
    --forge)              FORGES+=("$2"); shift 2 ;;
    --release)            RELEASE="$2"; shift 2 ;;
    --previous)           PREVIOUS="$2"; shift 2 ;;
    --snapshot-out)       SNAPSHOT_OUT="$2"; shift 2 ;;
    --images-out)         IMAGES_OUT="$2"; shift 2 ;;
    --out)                OUT="$2"; shift 2 ;;
    --title)              TITLE="$2"; shift 2 ;;
    --format)             FORMAT="$2"; shift 2 ;;
    --inventory-out)      INVENTORY_OUT="$2"; shift 2 ;;
    --detailed-out)       DETAILED_OUT="$2"; shift 2 ;;
    --debug)              set -x; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) usage_error "unknown option: $opt" ;;
  esac
done

case "$RESOLVE" in off|auto|crane|skopeo) ;; *) usage_error "--resolve-digests: must be off, auto, crane or skopeo" ;; esac
case "$FORMAT" in summary|inventory|detailed) ;; *) usage_error "--format: must be summary, inventory or detailed" ;; esac
$EXCLUDE_SET || EXCLUDED=("${DEFAULT_EXCLUDED_NAMESPACES[@]}")

for tool in kubectl jq; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

FORGES_JSON='{}'
for f in ${FORGES[@]+"${FORGES[@]}"}; do
  host="${f%%=*}" kind=""
  [[ "$f" == *=* ]] && kind="${f#*=}"
  case "$kind" in github|gitlab|bitbucket) ;; *) die "--forge $f: TYPE must be github, gitlab or bitbucket" ;; esac
  FORGES_JSON="$(jq -c --arg h "$host" --arg k "$kind" '.[$h] = $k' <<<"$FORGES_JSON")"
done

# Digest lookups in the registry.
RESOLVER=""
case "$RESOLVE" in
  crane|skopeo)
    command -v "$RESOLVE" >/dev/null || die "--resolve-digests $RESOLVE: '$RESOLVE' is not on PATH"
    RESOLVER="$RESOLVE" ;;
  auto)
    for t in crane skopeo; do
      if command -v "$t" >/dev/null; then RESOLVER="$t"; break; fi
    done
    [[ -n "$RESOLVER" ]] || echo "warning: --resolve-digests auto: neither crane nor skopeo found; skipping" >&2 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KUBECTL=(kubectl)
[[ -n "$KUBECONFIG_PATH" ]] && KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH")
[[ -n "$CONTEXT" ]] && KUBECTL+=(--context "$CONTEXT")

# ---------------------------------------------------------------------------- #
# jq library: everything except talking to kubectl and registries
# ---------------------------------------------------------------------------- #
JQ_LIB="$(cat <<'JQ'
# --- Generic helpers (Python-style truthiness, since "" is truthy in jq) ------ #
def truthy: . != null and . != false and . != 0 and . != "" and . != [] and . != {};
def or_($b): if truthy then . else $b end;
def pystrip: sub("\\A\\s+"; "") | sub("\\s+\\z"; "");
def key($kind; $ns; $name): if ($kind | truthy) then "\($kind)|\($ns)|\($name)" else "" end;
def pretty: if truthy then (split("|") as $p | "\($p[0]) \($p[1])/\($p[2])") else "" end;
def esc: (if . == null then "" else tostring end) | gsub("\\|"; "\\|") | gsub("\n"; " ");
def code: if truthy then "`\(esc)`" else "-" end;
def fmt_ref: (. // {}) | to_entries | map("\(.key) `\(.value)`") | join(", ") | or_("default");

def condition:
  ([(. // {} | .conditions // [])[] | select(.type == "Ready")][0]) as $c
  | if $c == null then ["Unknown", ""]
    else [($c.status // "Unknown"), (($c.message | or_("")) | pystrip)] end;

def flux_owner:
  (. // {}) as $l
  | if ($l["helm.toolkit.fluxcd.io/name"] | truthy) then
      key("HelmRelease"; $l["helm.toolkit.fluxcd.io/namespace"] // ""; $l["helm.toolkit.fluxcd.io/name"])
    elif ($l["kustomize.toolkit.fluxcd.io/name"] | truthy) then
      key("Kustomization"; $l["kustomize.toolkit.fluxcd.io/namespace"] // ""; $l["kustomize.toolkit.fluxcd.io/name"])
    else "" end;

def ref_key($default_ns):
  (. // {}) as $r | key($r.kind // ""; ($r.namespace | or_($default_ns)); $r.name // "");

# --- URLs (same splitting rules as Python's urllib.parse.urlsplit) ------------ #
def urlparts:
  . as $u
  | (if test("\\A[A-Za-z][A-Za-z0-9+.-]*:") then capture("\\A(?<s>[^:]*):(?<r>.*)\\z")
     else {s: "", r: $u} end) as $a
  | ($a.s | ascii_downcase) as $scheme
  | (if ($a.r | startswith("//")) then ($a.r[2:] | capture("\\A(?<n>[^/?#]*)(?<t>.*)\\z"))
     else {n: "", t: $a.r} end) as $b
  | ($b.t | capture("\\A(?<pq>[^#]*)(?:#(?<f>.*))?\\z")) as $c
  | ($c.pq | capture("\\A(?<p>[^?]*)(?:\\?(?<q>.*))?\\z")) as $d
  | {scheme: $scheme, netloc: $b.n, path: $d.p, query: ($d.q // ""), fragment: ($c.f // "")};

def hostname:
  urlparts.netloc | sub("\\A.*@"; "")
  | (if startswith("[") then ((capture("\\A\\[(?<h>[^\\]]*)\\]") | .h) // "") else sub(":.*\\z"; "") end)
  | ascii_downcase;

# Drop credentials embedded in a URL (https://user:token@host/...).
def clean_url:
  if (truthy | not) then ""
  else . as $u | urlparts as $p
    | if ($p.netloc | contains("@") | not) then $u
      else ($p.netloc | sub("\\A.*@"; "")) as $host
        | (if ($p.scheme | IN("http", "https", "oci", "s3", "gs")) then $host
           else ($p.netloc | sub("@[^@]*\\z"; "") | split(":")[0]) as $user
             | if $user != "" then "\($user)@\($host)" else $host end
           end) as $nl
        | (if $p.scheme != "" then "\($p.scheme):" else "" end) + "//" + $nl + $p.path
          + (if $p.query != "" then "?\($p.query)" else "" end)
          + (if $p.fragment != "" then "#\($p.fragment)" else "" end)
      end
  end;

def web_url:
  (. // "") | pystrip
  | sub("^ssh://(?:[^@/]+@)?(?<h>[^/:]+)(?::\\d+)?/"; "https://\(.h)/")
  | sub("^[^@/:]+@(?<h>[^:/]+):"; "https://\(.h)/")
  | sub("\\.git/?$"; "");

def forge_of($forges):
  hostname as $h
  | if ($forges | has($h)) then $forges[$h]
    else ([("github", "gitlab", "bitbucket") | select(. as $f | $h | contains($f))][0] // "") end;

def commit_link($url; $sha; $forges):
  ($url | web_url) as $base | ($base | forge_of($forges)) as $f
  | if $sha == "" or ($base | startswith("https://") | not) or $f == "" then
      (if $sha != "" then ($sha[:12] | code) else "-" end)
    else "[`\($sha[:12])`](\($base)/\({github: "commit", gitlab: "-/commit", bitbucket: "commits"}[$f])/\($sha))" end;

def compare_link($url; $old; $new; $forges):
  ($url | web_url) as $base | ($base | forge_of($forges)) as $f
  | if ($old == "" or $new == "" or ($base | startswith("https://") | not) or $f == "") then ""
    else {github: "[compare](\($base)/compare/\($old)...\($new))",
          gitlab: "[compare](\($base)/-/compare/\($old)...\($new))",
          bitbucket: "[compare](\($base)/branches/compare/\($new)%0D\($old))"}[$f] end;

# --- Flux revisions ----------------------------------------------------------- #
# 'main@sha1:abc..', 'v1.2.3@sha1:abc..', 'sha1:abc..', 'latest@sha256:..' and the
# legacy 'main/abc..' form -> [ref name, "algo:hash"]
def parse_revision:
  (. // "") as $r
  | ([$r | capture("^(?:(?<ref>.*)@)?(?<h>(?:sha1|sha256|sha384|sha512):[0-9a-f]+)$")][0]) as $m
  | if $m != null then [($m.ref // ""), $m.h]
    else ([$r | capture("^(?<ref>.*)/(?<h>[0-9a-f]{40})$")][0]) as $l
      | if $l != null then [$l.ref, "sha1:\($l.h)"] else [$r, ""] end
    end;

def bare_hash: (. // "") | if contains(":") then sub("\\A[^:]*:"; "") else . end;

def short_version:
  parse_revision as [$r, $h]
  | ($r | sub("^refs/(tags|heads)/"; "")) as $ref | ($h | bare_hash | .[:7]) as $hh
  | if $ref != "" and $hh != "" then "\($ref) (\($hh))" else ($ref | or_($hh | or_("-"))) end;

# --- Image references ---------------------------------------------------------- #
# 'redis:7' -> docker.io / library/redis / 7
def parse_image:
  ((. // "") | pystrip) as $img
  | (if ($img | contains("@")) then ($img | capture("\\A(?<r>[^@]*)@(?<d>.*)\\z") | [.r, .d]) else [$img, ""] end) as [$ref, $digest]
  | (if ($ref | split("/") | last // "" | contains(":")) then ($ref | capture("\\A(?<n>.*):(?<t>[^:]*)\\z"))
     else {n: $ref, t: ""} end) as $nt
  | ($nt.n | capture("\\A(?<f>[^/]*)(?:/(?<r>.*))?\\z")) as $fp
  | (if ($fp.r // "") != "" and (($fp.f | contains(".")) or ($fp.f | contains(":")) or $fp.f == "localhost")
     then [$fp.f, $fp.r] else ["docker.io", $nt.n] end) as [$reg0, $repo0]
  | (if $reg0 == "index.docker.io" or $reg0 == "registry-1.docker.io" then "docker.io" else $reg0 end) as $reg
  | (if $reg == "docker.io" and ($repo0 | contains("/") | not) then "library/\($repo0)" else $repo0 end) as $repo
  | {registry: $reg, repository: $repo,
     tag: (if $nt.t == "" and $digest == "" then "latest" else $nt.t end), digest: $digest};

def image_string($with_digest):
  "\(.registry)/\(.repository)"
  + (if (.tag | truthy) then ":\(.tag)" else "" end)
  + (if $with_digest and (.digest | truthy) then "@\(.digest)" else "" end);

# containerStatus.imageID -> [registry digest, local image id]
def parse_image_id:
  (. // "") | sub("^[a-z-]+://"; "")
  | if contains("@") then [capture("@(?<d>.*)\\z").d, ""]
    elif startswith("sha256:") then ["", .]
    else ["", ""] end;

# --- Flux objects --------------------------------------------------------------- #
def ready_fields: (.status | condition) as [$ready, $msg]
  | {ready: $ready, message: (if $ready != "True" then $msg else "" end)};

def collect_sources($lists):  # [[kind, items], ...]
  reduce ($lists[] as [$kind, $items] | $items[] | [$kind, .]) as [$kind, $s] ({};
    ($s.metadata) as $md | ($s.spec // {}) as $spec | ($s.status // {}) as $st
    | (($st.artifact | or_({})).revision // "") as $revision
    | ($revision | parse_revision) as [$resolved, $h]
    | (if $kind == "Bucket" then "\($spec.endpoint // "")/\($spec.bucketName // "")" else ($spec.url // "") end) as $url
    | .[key($kind; $md.namespace; $md.name)] = ({
        kind: $kind,
        url: ($url | clean_url),
        ref: (($spec.ref | or_({})) | with_entries(select((.value | type) == "string" and .value != ""))),
        type: ($spec.type // ""),
        revision: $revision,
        resolved_ref: $resolved,
        hash: $h,
        suspended: ($spec.suspend | truthy)
      } + ($s | ready_fields)));

def collect_kustomizations($items):
  reduce $items[] as $ks ({};
    ($ks.metadata) as $md | ($ks.spec // {}) as $spec | ($ks.status // {}) as $st
    | .[key("Kustomization"; $md.namespace; $md.name)] = ({
        parent: ($md.labels | flux_owner),
        source: ($spec.sourceRef | ref_key($md.namespace)),
        path: ($spec.path // "" | or_("./")),
        applied_revision: ($st.lastAppliedRevision // ""),
        attempted_revision: ($st.lastAttemptedRevision // ""),
        suspended: ($spec.suspend | truthy)
      } + ($ks | ready_fields)));

def collect_helmreleases($items):
  reduce $items[] as $hr ({};
    ($hr.metadata) as $md | ($hr.spec // {}) as $spec | ($hr.status // {}) as $st
    | ((($spec.chart | or_({})).spec) // {}) as $cs
    | (if ($cs | truthy) then
         [($cs.sourceRef | ref_key($md.namespace)), ($cs.version | or_("*")), ($cs.chart // "")]
       else  # spec.chartRef -> OCIRepository or HelmChart
         [($spec.chartRef | ref_key($md.namespace)), "", ""]
       end) as [$chart_source, $requested, $chart_ref]
    | ($st.history | or_([])) as $history
    | ($spec.targetNamespace | or_($md.namespace)) as $target_ns
    | (if ($spec.targetNamespace | truthy) then "\($spec.targetNamespace)-\($md.name)" else $md.name end) as $default_release
    | (if ($history | length) > 0 then  # helm.toolkit.fluxcd.io/v2 and v2beta2
         $history[0] as $h
         | {chart: ($h.chartName | or_($chart_ref)),
            chart_version: ($h.chartVersion // ""), app_version: ($h.appVersion // ""),
            chart_digest: ($h.ociDigest // ""),
            release_name: ($h.name | or_($spec.releaseName | or_($default_release))),
            helm_status: ($h.status // ""), deployed_at: ($h.lastDeployed // "")}
       else  # v2beta1: lastAppliedRevision is the chart version
         {chart: $chart_ref, chart_version: ($st.lastAppliedRevision // ""), app_version: "",
          chart_digest: "", release_name: ($spec.releaseName | or_($default_release)),
          helm_status: "", deployed_at: ""}
       end) as $hist
    | .[key("HelmRelease"; $md.namespace; $md.name)] = ({
        parent: ($md.labels | flux_owner),
        source: $chart_source,
        chart: $hist.chart,
        chart_path: (if ($chart_source | startswith("GitRepository|")) then $chart_ref else "" end),
        chart_version: $hist.chart_version,
        app_version: $hist.app_version,
        requested_version: $requested,
        chart_digest: $hist.chart_digest,
        release_name: $hist.release_name,
        target_namespace: $target_ns,
        helm_status: $hist.helm_status,
        deployed_at: $hist.deployed_at,
        attempted_revision: ($st.lastAttemptedRevision // ""),
        suspended: ($spec.suspend | truthy)
      } + ($hr | ready_fields)));

# [source key of the repo that delivered it, chain of Flux keys root -> owner]
def resolve_delivery($flux; $owner):
  {chain: [], seen: {}, cur: $owner, delivering: "", stop: false}
  | until(.stop or (.cur | truthy | not) or .seen[.cur];
      .seen[.cur] = true | .chain += [.cur]
      | $flux[.cur] as $obj
      | if $obj == null then .stop = true
        else (if (.delivering | truthy | not) and (.cur | startswith("Kustomization|"))
              then .delivering = $obj.source else . end)
          | .cur = $obj.parent
        end)
  | (if (.delivering | truthy | not) and ($flux | has($owner)) then .delivering = $flux[$owner].source else . end)
  | [.delivering, (.chain | reverse)];

# --- Workloads ------------------------------------------------------------------- #
def ctrl_ref:
  (.metadata.ownerReferences // []) as $r
  | ([$r[] | select(.controller | truthy)][0]) // $r[0];

# obj, its controller, that one's controller, ... (bottom -> top)
def owner_chain($idx; $fetched):
  {out: [.], seen: {(.metadata.uid // ""): true}, done: false}
  | until(.done;
      (.out[-1] | ctrl_ref) as $ref
      | if $ref == null or .seen[$ref.uid // ""] or $ref.kind == "Node" then .done = true
        else .seen[$ref.uid // ""] = true
          | .out += [$idx[$ref.uid // ""] // $fetched[$ref.uid // ""]
                     // error("owner \($ref.kind)/\($ref.name) was not fetched")]
        end)
  | .out;

# The object a person manages: skip Pods/ReplicaSets/Jobs that have a controller.
def workload($idx; $fetched):
  owner_chain($idx; $fetched) as $c
  | {i: ([range(0; $c | length)
          | select((($c[.].kind | IN("Pod", "ReplicaSet", "Job")) | not) or (. + 1 >= ($c | length)))][0]),
     chain: $c};

# Owners reached from this object that are neither listed nor fetched yet.
def missing_owner($idx; $fetched):
  {cur: ., seen: {(.metadata.uid // ""): true}, miss: null, done: false}
  | until(.done;
      (.cur | ctrl_ref) as $ref
      | if $ref == null or .seen[$ref.uid // ""] or $ref.kind == "Node" then .done = true
        else ($idx[$ref.uid // ""] // $fetched[$ref.uid // ""]) as $o
          | if $o == null then
              .miss = {namespace: (.cur.metadata.namespace // ""), kind: $ref.kind,
                       apiVersion: ($ref.apiVersion // ""), name: $ref.name, uid: ($ref.uid // "")}
              | .done = true
            else .seen[$ref.uid // ""] = true | .cur = $o end
        end)
  | .miss // empty;

def pod_template_spec:
  (.spec // {}) as $s
  | if .kind == "CronJob" then ($s.jobTemplate // {} | .spec // {} | .template // {} | .spec // {})
    elif .kind == "Pod" then $s
    else ($s.template // {} | .spec // {}) end;

def containers_of:
  ((.initContainers // [])[] | [., (if .restartPolicy == "Always" then "sidecar" else "init" end)]),
  ((.containers // [])[] | [., "container"]);

def uid_index: reduce .[] as $o ({}; .[$o.metadata.uid // ""] = $o);

def not_excluded($excluded): select((.metadata.namespace | IN($excluded[])) | not);

def workload_starts($excluded):
  (.objs[] | not_excluded($excluded)
   | select(((.kind | IN("ReplicaSet", "Job")) and (ctrl_ref != null)) | not)),
  (.pods[] | not_excluded($excluded));

# One row per workload container, before digests are settled.
def collect_entries($raw; $flux; $excluded; $include_unmanaged):
  ($raw.objs | uid_index) as $idx | ($raw.fetched) as $fetched
  | [
      # Desired state: pod templates of workloads (covers scaled-to-zero and idle CronJobs).
      ($raw.objs[] | not_excluded($excluded)
       | select(((.kind | IN("ReplicaSet", "Job")) and (ctrl_ref != null)) | not)
       | . as $o | workload($idx; $fetched) as $w
       | select($w.i == 0)
       | ($o | pod_template_spec | containers_of) as [$c, $ctype]
       | {w: $o, wi: 0, chain: $w.chain, cname: $c.name, ctype: $ctype, image: ($c.image // ""), run: null}),
      # Actual state: what pods run (also covers pods created by operators/CRs).
      ($raw.pods[] | not_excluded($excluded)
       | . as $p | workload($idx; $fetched) as $w
       | (reduce ((($p.status.initContainerStatuses // []) + ($p.status.containerStatuses // []))[]) as $s
            ({}; .[$s.name // ""] = $s)) as $statuses
       | ($p.spec // {} | containers_of) as [$c, $ctype]
       | (($statuses[$c.name] // {}).imageID // "" | parse_image_id) as [$d, $lid]
       | {w: $w.chain[$w.i], wi: $w.i, chain: $w.chain, cname: $c.name, ctype: $ctype,
          image: ($c.image // ""), run: [($c.image // ""), $d, $lid]})
    ]
  | reduce .[] as $ob ({};
      ([$ob.w.metadata.namespace, $ob.w.kind, $ob.w.metadata.name, $ob.cname] | tojson) as $k
      | (if has($k) then . else
           ([$ob.chain | reverse[] | .metadata.labels | flux_owner | select(. != "")][0] // "") as $owner
           | (if $owner != "" then resolve_delivery($flux; $owner) else ["", []] end) as [$source, $fchain]
           | ($ob.chain[-1]) as $top
           | .[$k] = {
               namespace: $ob.w.metadata.namespace, kind: $ob.w.kind, name: $ob.w.metadata.name,
               controlled_by: (if $ob.wi != (($ob.chain | length) - 1) then "\($top.kind)/\($top.metadata.name)" else "" end),
               container: $ob.cname, container_type: $ob.ctype, spec_image: $ob.image,
               owner: $owner, source: $source, chain: $fchain, _running: {}}
         end)
      | if $ob.run != null then .[$k]._running[$ob.run | tojson] += 1 else . end)
  | [.[] | select((.owner | truthy) or $include_unmanaged)];

def current_digests:
  .spec_image as $img
  | [(._running | keys[] | fromjson) | select(.[0] == $img) | .[1] | select(. != "")] | unique;

# Image references that need a registry lookup: no digest pinned or reported.
def lookup_refs:
  [.[] | select((.spec_image | parse_image | .digest) == "" and (current_digests | length) == 0)
   | .spec_image | parse_image | image_string(false)] | unique;

def finalize($resolved):  # $resolved: {ref: {digest, error}} or null when lookups are off
  del(._running) as $entry
  | (._running | to_entries | map((.key | fromjson) + [.value]) | sort
   | map({image: .[0], digest: .[1], image_id: .[2], pods: .[3]})) as $running
  | .spec_image as $spec
  | [$running[] | select(.image == $spec)] as $current
  | [$running[] | select(.image != $spec)] as $stale
  | ([$current[] | .digest | select(. != "")] | unique) as $cd
  | {p: ($spec | parse_image), w: [], ds: ""}
  | if .p.digest != "" then
      .ds = "pinned"
      | (.p.digest as $pd | if any($cd[]; . != $pd) then .w += ["running digest differs from the pinned digest"] else . end)
    elif ($cd | length) == 1 then .p.digest = $cd[0] | .ds = "running pods"
    elif ($cd | length) > 1 then
      .w += ["tag was re-pushed; pods run \($cd | length) different digests (" + ($cd | map(.[7:19]) | join(", ")) + ")"]
    elif any($current[]; .image_id != "") then .w += ["node reported no registry digest"]
    else . end
  | if .p.digest == "" and ($cd | length) == 0 and $resolved != null then
      ($resolved[.p | image_string(false)] // {digest: "", error: "lookup failed"}) as $r
      | if $r.digest != "" then .p.digest = $r.digest | .ds = "registry"
        else .w += ["registry lookup failed: \($r.error)"] end
    else . end
  | if .p.digest == "" and (.w | length) == 0 then
      .w += ["digest unknown" + (if ($running | length) > 0 then "" else " (no pods running)" end)]
    else . end
  | if ($stale | length) > 0 then
      ([$stale[].pods] | add) as $n
      | .w += ["rollout in progress: \($n) pod\(if $n != 1 then "s" else "" end) still on "
               + ([$stale[].image] | unique | join(", "))]
    else . end
  | . as $r
  | $entry + $r.p + {
      image: ($r.p | image_string(true)),
      digest_source: $r.ds,
      pods: ([$current[].pods] | add // 0),
      running: $running,
      warnings: $r.w};

def finalize_all($resolved):
  map(finalize($resolved))
  | sort_by([(.source == ""), .source, .owner, .namespace, .kind, .name, .container]);

# --- Diffing ------------------------------------------------------------------------ #
def entry_key: "\(.namespace)/\(.kind)/\(.name)/\(.container)";

def diff_images($previous; $current):
  (reduce $previous[] as $e ({}; .[$e | entry_key] = $e)) as $P
  | (reduce $current[] as $e ({}; .[$e | entry_key] = $e)) as $C
  | [(($C | keys) + ($P | keys) | unique)[] as $k | $P[$k] as $a | $C[$k] as $b
     | if $a != null and $b == null then ["Removed", $a, null]
       elif $b != null and $a == null then ["Added", null, $b]
       elif ($a | image_string(false)) != ($b | image_string(false))
            or (($a.digest | truthy) and ($b.digest | truthy) and $a.digest != $b.digest) then ["Updated", $a, $b]
       else empty end];

# [added, removed, common] keys, each sorted
def diff_dict($prev; $curr):
  ($prev | keys) as $p | ($curr | keys) as $c
  | [$c - $p, $p - $c, [$c[] | select(. as $k | $prev | has($k))]];

# --- Rendering ----------------------------------------------------------------------- #
def source_heading($sources):
  if . == "" then "Not managed by Flux"
  else pretty + (($sources[.] // {}).url as $u | if ($u | truthy) then " — \($u)" else "" end) end;

def git_ref_cell:  # 'tag v1.2.3' / 'branch main' resolved from the artifact revision
  (.resolved_ref // "") as $r
  | if ($r | startswith("refs/tags/")) then "tag `\($r[10:])`"
    elif ($r | startswith("refs/heads/")) then "branch `\($r[11:])`"
    elif (.ref | has("tag") or has("semver")) then (if $r != "" then "tag `\($r)`" else "-" end)
    else (if $r != "" then "`\($r)`" else "-" end) end;

def requested_cell($sources):
  if (.requested_version | truthy) then (.requested_version | code)
  else ($sources[.source]) as $src | (if $src != null then ($src.ref | fmt_ref) else "-" end) end;

def chart_source_cell($sources):
  ($sources[.source] // {}) as $s
  | (.source | pretty | or_("-")) as $label
  | (($s.url // "") + (if (.chart_path | truthy) then " path `\(.chart_path)`" else "" end)) as $detail
  | ($label | esc) + (if $detail != "" then "<br>\($detail | esc)" else "" end);

def repo_label($sources):  # human name for a source: the repository path from its URL
  . as $skey | $sources[$skey] as $s
  | if $skey == "" then "Not managed by Flux"
    elif $s == null or ($s.url | truthy | not) then ($skey | pretty)
    else ($s.url | web_url | urlparts.path | gsub("\\A/+|/+\\z"; "")) | or_($skey | pretty) end;

def image_label: .repository | split("/") | .[-2:] | join("/");

def tag_or_digest($e):
  if $e == null then "-"
  else $e.tag | or_(if ($e.digest | truthy) then ($e.digest | gsub("sha256:"; "") | .[:7]) else "-" end) end;

def hash_cell: "\(.resolved_ref | code) \(.hash | bare_hash | .[:12] | code)";

def render_changes($snap; $prev; $forges):
  $snap.sources as $sources | $prev.sources as $psources
  | ($sources | with_entries(select(.value.kind != "HelmRepository"))) as $cur
  | ($psources | with_entries(select(.value.kind != "HelmRepository"))) as $old
  | diff_dict($old; $cur) as [$added, $removed, $common]
  | [ ($common[] | . as $k | $psources[$k] as $a | $sources[$k] as $b
       | select([$a.url, $a.ref, $a.hash] != [$b.url, $b.ref, $b.hash])
       | ([ (if $a.url != $b.url then "URL \($a.url | esc) → \($b.url | esc)" else empty end),
            (if $a.ref != $b.ref then "ref \($a.ref | fmt_ref) → \($b.ref | fmt_ref)" else empty end) ]) as $what
       | (if $b.kind == "GitRepository" then compare_link($b.url; $a.hash | bare_hash; $b.hash | bare_hash; $forges) else "" end) as $link
       | "| \($k | pretty | esc) | \($b.url | esc) | \($a | hash_cell) | \($b | hash_cell) | \($what + (if $link != "" then [$link] else [] end) | join("; ")) |"),
      ($added[] | . as $k | $sources[$k] as $b
       | "| \($k | pretty | esc) | \($b.url | esc) | new | \($b | hash_cell) | |"),
      ($removed[] | . as $k | $psources[$k] as $a
       | "| \($k | pretty | esc) | \($a.url | esc) | \($a | hash_cell) | removed | |") ] as $srows
  | $snap.helmreleases as $hrs | $prev.helmreleases as $phrs
  | diff_dict($phrs; $hrs) as [$hadded, $hremoved, $hcommon]
  | [ ($hcommon[] | . as $k | $phrs[$k] as $a | $hrs[$k] as $b
       | select(any("chart", "chart_version", "app_version", "chart_digest", "source"; $a[.] != $b[.]))
       | "| Updated | \($k | pretty | esc) | \($a.chart | code) \($a.chart_version | code) (app \($a.app_version | code)) | \($b.chart | code) \($b.chart_version | code) (app \($b.app_version | code)) |"),
      ($hadded[] | . as $k | $hrs[$k] as $b
       | "| Added | \($k | pretty | esc) | - | \($b.chart | code) \($b.chart_version | code) (app \($b.app_version | code)) |"),
      ($hremoved[] | . as $k | $phrs[$k] as $a
       | "| Removed | \($k | pretty | esc) | \($a.chart | code) \($a.chart_version | code) | - |") ] as $hrows
  | diff_images($prev.images; $snap.images) as $changes
  | ($psources + $sources) as $all_sources
  | ( (if ($srows | length) > 0 then ["### Sources", "", "| Source | URL | From | To | Details |", "|---|---|---|---|---|"] + $srows + [""] else [] end)
    + (if ($hrows | length) > 0 then ["### Helm charts", "", "| Change | HelmRelease | From | To |", "|---|---|---|---|"] + $hrows + [""] else [] end)
    + (if ($changes | length) > 0 then
         ["### Images", ""]
         + ([ ([$changes[] | (.[2] // .[1]).source] | unique | sort_by([(. == ""), .]))[] as $skey
             | ["#### \($skey | source_heading($all_sources) | esc)", "",
                "| Change | Workload | Container | From | To |", "|---|---|---|---|---|"]
               + [ $changes[] | select((.[2] // .[1]).source == $skey) | . as [$change, $a, $b] | ($b // $a) as $e
                   | "| \($change) | \($e.namespace | esc)/\($e.kind)/\($e.name | esc) | \($e.container | esc) | \(if $a != null then ($a.image | code) else "-" end) | \(if $b != null then ($b.image | code) else "-" end) |" ]
               + [""] ] | add)
       else [] end) )
  | if length == 0 then ["No source, chart or image changes.", ""] else . end;

def collect_warnings($snap):  # [[subject, message]] for everything a human should look at
  $snap.sources as $sources | $snap.kustomizations as $ks | $snap.helmreleases as $hrs
  | [ ($sources | to_entries | sort_by(.key)[] | .value as $s | select($s.ready != "True")
       | [(.key | pretty), "not ready: \($s.message | or_($s.ready))"]),
      ($ks + $hrs | to_entries | sort_by(.key)[] | .value as $o
       | if ($o.suspended | truthy) then [(.key | pretty), "suspended"]
         elif $o.ready != "True" then [(.key | pretty), "not ready: \($o.message | or_($o.ready))"]
         else empty end),
      ($ks | to_entries | sort_by(.key)[] | .value as $o | $sources[$o.source] as $src
       | select($src != null and ($src.revision | truthy) and ($o.applied_revision | truthy) and $src.revision != $o.applied_revision)
       | [(.key | pretty), "behind its source: applied \($o.applied_revision | short_version), source is at \($src.revision | short_version)"]),
      ($snap.images[] | . as $e | .warnings[]
       | ["\($e.namespace)/\($e.name)\(if $e.container == $e.name then "" else " (\($e.container))" end)", .]) ];

def render_header($snap; $prev; $title; $default_heading):
  ($title | or_(if ($snap.release | truthy) then "Release \($snap.release)" else $default_heading end)) as $heading
  | (["`\($snap.context)`", "Kubernetes \($snap.kubernetes_version)", "Flux \($snap.flux_version)",
      ($snap.generated_at[:16] + " UTC")]
     + (if $prev != null then ["compared with \($prev.release | or_($prev.generated_at[:16]))"] else [] end)) as $meta
  | ["# \($heading | esc)", "", ($meta | join(" · ")), ""];

def render_deployed($snap; $forges; $level):
  $snap.sources as $sources | $snap.helmreleases as $hrs | $snap.images as $images
  | ($sources | to_entries | map(select(.value.kind | IN("GitRepository", "OCIRepository", "Bucket")))) as $repos
  | (if ($repos | length) > 0 then
       ["\($level) Repositories", "", "| Repository | Version | Commit / digest |", "|---|---|---|"]
       + [ $repos | to_entries | sort_by([(.value.key | repo_label($sources)), .key])[] | .value
           | .key as $k | .value as $s
           | ($s.revision | parse_revision) as [$ref0, $h]
           | ($ref0 | sub("^refs/(tags|heads)/"; "")) as $ref
           | (if $s.kind == "GitRepository" then commit_link($s.url; $h | bare_hash; $forges) else ($h | bare_hash | .[:12] | code) end) as $hcell
           | "| \($k | repo_label($sources) | esc) | \($ref | code) | \($hcell) |" ]
       + [""]
     else [] end)
  + (if ($hrs | length) > 0 then
       ["\($level) Helm charts", "", "| Helm chart | Release | Version |", "|---|---|---|"]
       + [ $hrs | to_entries | sort_by([.value.chart, .key])[] | .value as $h
           | "| \($h.chart | code) | \($h.target_namespace + "/" + $h.release_name | esc) | \($h.chart_version | code) |" ]
       + [""]
     else [] end)
  + (if ($images | length) > 0 then
       (reduce $images[] as $e ({used: {}, by: {}};
          .used[$e.image] += [$e.name] | .by[$e.image] = $e)) as $agg
       | ["\($level) Images", "", "| Image | Tag | Digest | Used by |", "|---|---|---|---|"]
       + [ $agg.by | to_entries | sort_by([(.value.registry + "/" + .value.repository), .key])[]
           | .key as $ref | .value as $e
           | ($agg.used[$ref] | unique) as $names
           | (($names[:3] | join(", ")) + (if ($names | length) > 3 then " +\(($names | length) - 3)" else "" end)) as $who
           | "| \($e.registry + "/" + $e.repository | code) | \($e.tag | code) | \(if ($e.digest | truthy) then ($e.digest | code) else "⚠️ unknown" end) | \($who | esc) |" ]
       + [""]
     else [] end);

def render_summary($snap; $prev; $title; $forges):
  $snap.sources as $sources | $snap.kustomizations as $ks | $snap.helmreleases as $hrs | $snap.images as $images
  | ($ks + $hrs) as $lookup
  | render_header($snap; $prev; $title; "Release notes")
  + (if $prev == null then [] else
      # What changed, grouped by the repo that delivers it
      $prev.sources as $psources | $prev.helmreleases as $phrs
      | ($psources + $sources) as $all_sources
      | def ensure($k): if .groups | has($k) then . else .groups[$k] = {source: null, lines: [], ord: .n} | .n += 1 end;
        {groups: {}, n: 0, chart_line: {}, nested: {}}
      | reduce ((($sources | keys) + ($psources | keys)) | unique)[] as $k (.;
          $psources[$k] as $a | $sources[$k] as $b
          | if ($a // $b).kind == "HelmRepository" then .
            elif $a != null and $b != null and [$a.url, $a.ref, $a.hash] == [$b.url, $b.ref, $b.hash] then .
            elif $a != null and $b != null then
              (if $b.kind == "GitRepository" then compare_link($b.url; $a.hash | bare_hash; $b.hash | bare_hash; $forges) else "" end) as $link
              | ensure($k)
              | .groups[$k].source = "\($a.revision | short_version) → \($b.revision | short_version)" + (if $link != "" then " (\($link))" else "" end)
            else ensure($k) | .groups[$k].source = (if $b != null then "new source" else "source removed" end) end)
      | reduce ((($hrs | keys) + ($phrs | keys)) | unique)[] as $k (.;
          $phrs[$k] as $a | $hrs[$k] as $b
          | if $a != null and $b != null and all("chart", "chart_version", "chart_digest"; $a[.] == $b[.]) then .
            else
              (resolve_delivery(if $b != null then $lookup else ($prev.kustomizations + $phrs) end; $k)[0]) as $skey
              | (($b // $a).chart) as $name
              | (if $a != null and $b != null then "\($a.chart_version) → \($b.chart_version)"
                 elif $b != null then "added, \($b.chart_version)" else "removed" end) as $change
              | ($k | split("|")[2]) as $hr_name
              | ("`\($name | esc)`" + (if $hr_name == $name then "" else " (\($hr_name | esc))" end)) as $label
              | ensure($skey)
              | .groups[$skey].lines += ["Chart \($label): \($change)"]
              | .chart_line[$k] = [$skey, (.groups[$skey].lines | length) - 1]
            end)
      | reduce diff_images($prev.images; $images)[] as [$change, $a, $b] (.;
          ($b // $a) as $e
          | (if ($e.repository | split("/") | last) == $e.name then "" else " in \($e.name | esc)" end) as $where
          | (if $change == "Added" then "`\($b | image_label | esc):\(tag_or_digest($b) | esc)` added\($where)"
             elif $change == "Removed" then "`\($a | image_label | esc)` removed\($where)"
             elif ($a | image_string(false)) == ($b | image_string(false)) then
               "`\($b | image_label | esc)` \(tag_or_digest($b) | esc) re-pushed\($where) (digest \($a.digest[7:14]) → \($b.digest[7:14]))"
             elif $a.repository != $b.repository or $a.registry != $b.registry then
               "`\($a | image_string(false) | esc)` → `\($b | image_string(false) | esc)`\($where)"
             else "`\($b | image_label | esc)` \(tag_or_digest($a) | esc) → \(tag_or_digest($b) | esc)\($where)" end) as $text
          | if .chart_line | has($e.owner) then .nested[.chart_line[$e.owner] | tojson] += [$text]  # caused by a chart upgrade
            else ensure($e.source) | .groups[$e.source].lines += [$text] end)
      | . as $st
      | ["## What changed", ""]
      + (if ($st.groups | length) == 0 then ["Nothing changed since the last release.", ""] else [] end)
      + ([ $st.groups | to_entries | sort_by([(.key == ""), (.key | repo_label($all_sources)), .value.ord])[]
           | .key as $skey | .value as $g
           | ["**\($skey | repo_label($all_sources) | esc)**" + (if ($g.source | truthy) then " — \($g.source)" else "" end)]
             + [ $g.lines | to_entries[] | "- \(.value)", ($st.nested[[$skey, .key] | tojson] // [] | .[] | "  - \(.)") ]
             + [""] ] | add // [])
    end)
  # Needs attention
  + ((reduce collect_warnings($snap)[] as [$s, $m] ({order: [], msgs: {}};
        (if .msgs | has($s) then . else .order += [$s] end) | .msgs[$s] += [$m])) as $w
     | [$w.order[] | [., ($w.msgs[.] | join("; "))]] as $warn
     | if ($warn | length) > 0 then
         ["## Needs attention", ""]
         + [$warn[:10][] | "- **\(.[0] | esc)**: \(.[1] | esc)"]
         + (if ($warn | length) > 10 then ["- …and \(($warn | length) - 10) more (see the full report)"] else [] end)
         + [""]
       else [] end)
  + ["## Deployed", ""] + render_deployed($snap; $forges; "###")
  | join("\n");

def render_inventory($snap; $prev; $title; $forges):
  render_header($snap; null; $title; "Deployed versions") + render_deployed($snap; $forges; "##") | join("\n");

def render_detailed($snap; $prev; $title; $forges):
  $snap.sources as $sources | $snap.kustomizations as $ks | $snap.helmreleases as $hrs | $snap.images as $images
  | def of_kind($k): $sources | with_entries(select(.value.kind == $k)) | to_entries | sort_by(.key);
    of_kind("GitRepository") as $git | of_kind("OCIRepository") as $oci
  | of_kind("Bucket") as $buckets | of_kind("HelmRepository") as $helmrepos
  | ["# \($title | or_(if ($snap.release | truthy) then "Release \($snap.release)" else "Release notes" end))", "",
     "- **Cluster context:** `\($snap.context)`",
     "- **Kubernetes:** `\($snap.kubernetes_version)`",
     "- **Flux:** `\($snap.flux_version)`",
     "- **Generated:** \($snap.generated_at)"]
  + (if $prev != null then ["- **Compared with:** \($prev.release | or_("snapshot")) (\($prev.generated_at))"] else [] end)
  + ["- **Inventory:** \($git | length) Git repositories, \($oci | length) OCI repositories, \($ks | length) Kustomizations, \($hrs | length) HelmReleases, \([$images[].image] | unique | length) unique images in \($images | length) containers", ""]
  + (if $prev != null then ["## Changes since \($prev.release | or_("previous snapshot"))", ""] + render_changes($snap; $prev; $forges) else [] end)
  + (collect_warnings($snap) as $warn
     | if ($warn | length) > 0 then ["## Warnings", ""] + [$warn[] | "- **\(.[0] | esc)**: \(.[1] | esc)"] + [""] else [] end)
  + ["## Flux sources", ""]
  + (if ($git | length) > 0 then
       ["### Git repositories", "", "| GitRepository | URL | Ref (spec) | Resolved | Commit | Ready |", "|---|---|---|---|---|---|"]
       + [$git[] | .key as $k | .value as $s
          | "| \($k | pretty | esc) | \($s.url | esc) | \($s.ref | fmt_ref) | \($s | git_ref_cell) | \(commit_link($s.url; $s.hash | bare_hash; $forges))<br>`\($s.hash | bare_hash | or_("-"))` | \($s.ready) |"]
       + [""] else [] end)
  + (if ($oci | length) > 0 then
       ["### OCI repositories", "", "| OCIRepository | URL | Ref (spec) | Resolved | Digest | Ready |", "|---|---|---|---|---|---|"]
       + [$oci[] | .key as $k | .value as $s
          | "| \($k | pretty | esc) | \($s.url | esc) | \($s.ref | fmt_ref) | \($s.resolved_ref | code) | \($s.hash | code) | \($s.ready) |"]
       + [""] else [] end)
  + (if ($buckets | length) > 0 then
       ["### Buckets", "", "| Bucket | Location | Revision | Ready |", "|---|---|---|---|"]
       + [$buckets[] | .key as $k | .value as $s
          | "| \($k | pretty | esc) | \($s.url | esc) | \($s.revision | code) | \($s.ready) |"]
       + [""] else [] end)
  + (if ($helmrepos | length) > 0 then
       ["### Helm repositories", "", "| HelmRepository | URL | Type | Ready |", "|---|---|---|---|"]
       + [$helmrepos[] | .key as $k | .value as $s
          | "| \($k | pretty | esc) | \($s.url | esc) | \($s.type | or_("default") | esc) | \($s.ready) |"]
       + [""] else [] end)
  + (if ($ks | length) > 0 then
       ["## Kustomizations", "", "| Kustomization | Source | Path | Applied revision | Ready |", "|---|---|---|---|---|"]
       + [$ks | to_entries | sort_by(.key)[] | .key as $k | .value as $o
          | "| \($k | pretty | esc) | \($o.source | pretty | esc) | \($o.path | code) | \($o.applied_revision | code) | \(if ($o.suspended | truthy) then "suspended" else $o.ready end) |"]
       + [""] else [] end)
  + (if ($hrs | length) > 0 then
       ["## Helm releases", "",
        "| HelmRelease | Release | Chart | Version | App version | Requested | Chart source | Chart digest | Ready |",
        "|---|---|---|---|---|---|---|---|---|"]
       + [$hrs | to_entries | sort_by(.key)[] | .key as $k | .value as $h
          | "| \($k | pretty | esc) | \($h.target_namespace + "/" + $h.release_name | code) | \($h.chart | code) | \($h.chart_version | code) | \($h.app_version | code) | \($h | requested_cell($sources)) | \($h | chart_source_cell($sources)) | \($h.chart_digest | code) | \(if ($h.suspended | truthy) then "suspended" else $h.ready end) |"]
       + [""] else [] end)
  # Images by delivering repo -> Flux owner
  + ["## Images", ""]
  + ([ ([$images[].source] | unique | sort_by([(. == ""), .]))[] as $skey
       | $sources[$skey] as $s
       | ["### \($skey | source_heading($sources) | esc)"]
       + (if $s != null then
            ["Ref \($s.ref | fmt_ref), resolved \(if $s.kind == "GitRepository" then ($s | git_ref_cell) else ($s.resolved_ref | code) end), \(if $s.kind == "GitRepository" then "commit" else "revision" end) `\($s.hash | bare_hash | or_($s.revision | or_("-")))`"]
          else [] end)
       + [""]
       + ([ ([$images[] | select(.source == $skey) | .owner] | unique)[] as $owner
            | [$images[] | select(.source == $skey and .owner == $owner)] as $items
            | ["#### \($owner | pretty | esc | or_("No Flux owner"))"]
            + (if $hrs | has($owner) then $hrs[$owner] as $h
                 | ["Chart \($h.chart | code) \($h.chart_version | code) (app \($h.app_version | code))  "]
               elif $ks | has($owner) then
                 ["Path \($ks[$owner].path | code), applied \($ks[$owner].applied_revision | code)  "]
               else [] end)
            + (if ($items[0].chain | length) > 1 then ["Applied via: " + ($items[0].chain | map(pretty | esc) | join(" → "))] else [] end)
            + ["", "| Workload | Container | Image | Digest from | Pods |", "|---|---|---|---|---|"]
            + [$items[]
               | ("\(.namespace | esc)/\(.kind)/\(.name | esc)" + (if (.controlled_by | truthy) then "<br>(managed by \(.controlled_by | esc))" else "" end)) as $wl
               | ((.container | esc) + (if .container_type == "container" then "" else " (\(.container_type))" end)) as $ctr
               | "| \($wl) | \($ctr) | \(.image | code) | \(.digest_source | or_("⚠️ unknown")) | \(.pods) |"]
            + [""] ] | add // [])
     ] | add // [])
  + ["## All images", "", "```"] + ([$images[].image] | unique) + ["```", ""]
  | join("\n");

def render($fmt; $snap; $prev; $title; $forges):
  if $fmt == "summary" then render_summary($snap; $prev; $title; $forges)
  elif $fmt == "inventory" then render_inventory($snap; $prev; $title; $forges)
  else render_detailed($snap; $prev; $title; $forges) end;
JQ
)"

jqlib() {  # jqlib [jq options...] PROGRAM [files...]: run a program with the library loaded
  local args=() prog
  while [[ $# -gt 0 && "$1" == -* ]]; do
    case "$1" in
      --arg|--argjson|--slurpfile|--rawfile) args+=("$1" "$2" "$3"); shift 3 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  prog="$1"; shift
  jq "${args[@]}" "$JQ_LIB
$prog" "$@"
}

# ---------------------------------------------------------------------------- #
# kubectl
# ---------------------------------------------------------------------------- #
# get_list RESOURCE NAMESPACE ALLOW_FAIL OUTFILE: list objects (all namespaces if NAMESPACE is empty)
get_list() {
  local resource="$1" ns="$2" allow_fail="$3" out="$4" args
  args=(get "$resource" -o json)
  if [[ -n "$ns" ]]; then args+=(-n "$ns"); else args+=(-A); fi
  if ! "${KUBECTL[@]}" "${args[@]}" >"$out" 2>"$TMP/err"; then
    if [[ "$allow_fail" == true ]]; then echo '{"items":[]}' >"$out"; return 0; fi
    echo "kubectl ${args[*]} failed:" >&2
    sed -e 's/[[:space:]]*$//' "$TMP/err" >&2
    exit 1
  fi
  [[ -s "$out" ]] || echo '{"items":[]}' >"$out"
}

# get_one RESOURCE NAMESPACE NAME OUTFILE: one object, "null" if it can't be read
get_one() {
  local args=(get "$1" "$3" -o json)
  [[ -n "$2" ]] && args+=(-n "$2")
  if ! "${KUBECTL[@]}" "${args[@]}" >"$4" 2>/dev/null || [[ ! -s "$4" ]]; then echo null >"$4"; fi
}

# ---------------------------------------------------------------------------- #
# Previous snapshot
# ---------------------------------------------------------------------------- #
PREV_FILE="$TMP/previous.json"
echo null >"$PREV_FILE"
if [[ -n "$PREVIOUS" ]]; then
  [[ -r "$PREVIOUS" ]] || die "--previous $PREVIOUS: cannot read the file"
  jq -e . "$PREVIOUS" >/dev/null 2>&1 || die "--previous $PREVIOUS: not valid JSON"
  if [[ "$(jq -r '.schema' "$PREVIOUS")" == "$SCHEMA" ]]; then
    cp "$PREVIOUS" "$PREV_FILE"
  else
    echo "warning: $PREVIOUS uses an older snapshot format; skipping the diff" >&2
  fi
fi

# ---------------------------------------------------------------------------- #
# Read the cluster
# ---------------------------------------------------------------------------- #
get_one namespace "" "$FLUX_NS" "$TMP/flux-ns.json"
get_list kustomizations.kustomize.toolkit.fluxcd.io "" true "$TMP/ks.json"
get_list helmreleases.helm.toolkit.fluxcd.io "" true "$TMP/hr.json"
get_list gitrepositories.source.toolkit.fluxcd.io "" true "$TMP/git.json"
get_list ocirepositories.source.toolkit.fluxcd.io "" true "$TMP/oci.json"
get_list buckets.source.toolkit.fluxcd.io "" true "$TMP/bucket.json"
get_list helmrepositories.source.toolkit.fluxcd.io "" true "$TMP/helmrepo.json"
get_list "$TEMPLATE_RESOURCES" "$NAMESPACE" false "$TMP/objs.json"
get_list pods "$NAMESPACE" false "$TMP/pods.json"

if [[ -n "$CONTEXT" ]]; then
  CTX="$CONTEXT"
else
  CTX="$("${KUBECTL[@]}" config current-context 2>/dev/null || true)"
  CTX="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$CTX")"
  [[ -n "$CTX" ]] || CTX="unknown"
fi
if "${KUBECTL[@]}" version -o json >"$TMP/version.json" 2>/dev/null; then
  K8S_VERSION="$(jq -r '.serverVersion.gitVersion // "unknown"' "$TMP/version.json" 2>/dev/null || echo unknown)"
else
  K8S_VERSION="unknown"
fi
GENERATED_AT="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
EXCLUDED_JSON="$(printf '%s\n' ${EXCLUDED[@]+"${EXCLUDED[@]}"} | jq -R . | jq -sc .)"

# Owners that aren't in the lists above (custom resources created by operators, or
# objects outside --namespace) are fetched one by one, until every chain is complete.
echo '{}' >"$TMP/fetched.json"
while :; do
  jqlib -c --argjson excluded "$EXCLUDED_JSON" --slurpfile fetched "$TMP/fetched.json" '
    (.[0].items | uid_index) as $idx
    | {objs: .[0].items, pods: .[1].items}
    | [workload_starts($excluded) | missing_owner($idx; $fetched[0])] | unique_by(.uid) | .[]
  ' -s "$TMP/objs.json" "$TMP/pods.json" >"$TMP/missing.jsonl"
  [[ -s "$TMP/missing.jsonl" ]] || break
  while IFS= read -r ref; do
    IFS=$'\t' read -r r_ns r_kind r_api r_name r_uid < <(jq -r '[.namespace, .kind, .apiVersion, .name, .uid] | @tsv' <<<"$ref")
    resource="$(tr '[:upper:]' '[:lower:]' <<<"$r_kind")"
    [[ "$r_api" == */* ]] && resource="$resource.${r_api%%/*}"
    get_one "$resource" "$r_ns" "$r_name" "$TMP/owner.json"
    # No permission or gone: keep a stub so the chain still names it.
    jq --slurpfile o "$TMP/owner.json" --argjson ref "$ref" '
      .[$ref.uid] = (($o[0] // {kind: $ref.kind, metadata: {name: $ref.name, namespace: $ref.namespace,
                                                              uid: $ref.uid, labels: {}}})
                     | .kind = (.kind // $ref.kind))
    ' "$TMP/fetched.json" >"$TMP/fetched.next" && mv "$TMP/fetched.next" "$TMP/fetched.json"
  done <"$TMP/missing.jsonl"
done

# ---------------------------------------------------------------------------- #
# Build the snapshot
# ---------------------------------------------------------------------------- #
jqlib -n \
  --slurpfile ks "$TMP/ks.json" --slurpfile hr "$TMP/hr.json" \
  --slurpfile git "$TMP/git.json" --slurpfile oci "$TMP/oci.json" \
  --slurpfile bucket "$TMP/bucket.json" --slurpfile helmrepo "$TMP/helmrepo.json" \
  --slurpfile fluxns "$TMP/flux-ns.json" --slurpfile prev "$PREV_FILE" \
  --arg schema "$SCHEMA" --arg release "$RELEASE" --arg context "$CTX" \
  --arg k8s "$K8S_VERSION" --arg generated "$GENERATED_AT" '
  {schema: ($schema | tonumber),
   release: $release,
   previous_release: (($prev[0] // {}).release // ""),
   context: $context,
   kubernetes_version: $k8s,
   flux_version: ((($fluxns[0] // {}).metadata.labels | or_({}))["app.kubernetes.io/version"] // "unknown"),
   generated_at: $generated,
   sources: collect_sources([["GitRepository", $git[0].items], ["OCIRepository", $oci[0].items],
                             ["Bucket", $bucket[0].items], ["HelmRepository", $helmrepo[0].items]]),
   kustomizations: collect_kustomizations($ks[0].items),
   helmreleases: collect_helmreleases($hr[0].items)}
' >"$TMP/snap.json"

jqlib --argjson excluded "$EXCLUDED_JSON" --argjson unmanaged "$INCLUDE_UNMANAGED" \
  --slurpfile snap "$TMP/snap.json" --slurpfile fetched "$TMP/fetched.json" '
  ($snap[0].kustomizations + $snap[0].helmreleases) as $flux
  | collect_entries({objs: .[0].items, pods: .[1].items, fetched: $fetched[0]}; $flux; $excluded; $unmanaged)
' -s "$TMP/objs.json" "$TMP/pods.json" >"$TMP/entries.json"

# Registry lookups for images no pod reports a digest for.
echo null >"$TMP/resolved.json"
if [[ "$RESOLVE" != "off" ]]; then
  echo '{}' >"$TMP/resolved.json"
  jqlib -r 'lookup_refs[]' "$TMP/entries.json" >"$TMP/lookups.txt"
  while IFS= read -r ref; do
    digest="" err=""
    if [[ -z "$RESOLVER" ]]; then
      err="no crane/skopeo available"
    elif [[ "$RESOLVER" == crane ]]; then
      rc=0; timeout 90 crane digest "$ref" >"$TMP/out" 2>"$TMP/err" </dev/null || rc=$?
      out="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$TMP/out")"
      if [[ $rc -eq 0 && "$out" == sha256:* ]]; then digest="$out"; fi
    else
      rc=0; timeout 90 skopeo inspect --raw "docker://$ref" >"$TMP/out" 2>"$TMP/err" </dev/null || rc=$?
      if [[ $rc -eq 0 && -s "$TMP/out" ]]; then digest="sha256:$(sha256sum "$TMP/out" | cut -d' ' -f1)"; fi
    fi
    if [[ -n "$RESOLVER" && -z "$digest" ]]; then
      if [[ $rc -eq 124 ]]; then
        err="registry lookup timed out"
      else
        err="$(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$TMP/err" | tail -n 1 | sed -e 's/^[[:space:]]*//')"
        [[ -n "$err" ]] || err="lookup failed"
      fi
    fi
    jq --arg ref "$ref" --arg d "$digest" --arg e "$err" '.[$ref] = {digest: $d, error: $e}' \
      "$TMP/resolved.json" >"$TMP/resolved.next" && mv "$TMP/resolved.next" "$TMP/resolved.json"
  done <"$TMP/lookups.txt"
fi

jqlib --slurpfile resolved "$TMP/resolved.json" --slurpfile entries "$TMP/entries.json" '
  .images = ($entries[0] | finalize_all($resolved[0]))
' "$TMP/snap.json" >"$TMP/snapshot.json"

# ---------------------------------------------------------------------------- #
# Outputs
# ---------------------------------------------------------------------------- #
render() {  # render FORMAT
  jqlib -r --slurpfile prev "$PREV_FILE" --argjson forges "$FORGES_JSON" --arg fmt "$1" --arg title "$TITLE" '
    render($fmt; .; $prev[0]; (if $title == "" then null else $title end); $forges)
  ' "$TMP/snapshot.json"
}

if [[ -n "$SNAPSHOT_OUT" ]]; then
  jq -S -a --indent 2 . "$TMP/snapshot.json" >"$SNAPSHOT_OUT"
fi
if [[ -n "$IMAGES_OUT" ]]; then
  jq -r '[.images[].image] | unique | join("\n")' "$TMP/snapshot.json" >"$IMAGES_OUT"
fi
if [[ -n "$INVENTORY_OUT" ]]; then render inventory >"$INVENTORY_OUT"; fi
if [[ -n "$DETAILED_OUT" ]]; then render detailed >"$DETAILED_OUT"; fi
if [[ -n "$OUT" ]]; then render "$FORMAT" >"$OUT"; else render "$FORMAT"; fi
