#!/bin/bash
# EC2 user-data that fails loudly instead of leaving a half-configured instance.
#
# - Any error (or unset variable, or failed pipe) stops the script.
# - Flaky steps (DNS, EFS, domain join, AWS API calls) are retried with backoff.
# - Before declaring success, the result is validated.
# - On failure: log, optional SNS alert, tag the instance, tell the ASG lifecycle
#   hook to ABANDON (if used), and shut down. On success: tag and CONTINUE.
#
# Everything that is the same in every environment (packages, sssd/realmd,
# amazon-efs-utils, jq, config templates) is expected to be baked into the AMI.
# This script only does per-environment / per-instance work.

set -Eeuo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1
echo "=== user-data start $(date -Is) ==="

# ---------------------------------------------------------------------------
# Settings. Leave a value empty to turn that feature off.
# ---------------------------------------------------------------------------
APP=myapp
SNS_TOPIC_ARN=""              # e.g. arn:aws:sns:us-east-1:123456789012:bootstrap-failures
LIFECYCLE_HOOK=""             # name of the ASG launch lifecycle hook, if any
SHUTDOWN_ON_FAILURE=true      # stop the instance on failure (disk + logs are kept)
EFS_MOUNT=/mnt/efs

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date +%T)] $*" >&2; }

# usage: retry <attempts> <command...>
# Exponential backoff starting at 5s, capped at 60s.
# NOTE: inside a retried *function*, bash ignores `set -e`, so only the
# function's return status counts. Chain steps with && or return explicitly.
retry() {
  local max=$1; shift
  local n=1 delay=5
  until "$@"; do
    if (( n >= max )); then
      log "FAILED after $n attempts: $*"
      return 1
    fi
    log "attempt $n failed: $*  (retrying in ${delay}s)"
    sleep "$delay"
    n=$(( n + 1 ))
    delay=$(( delay * 2 > 60 ? 60 : delay * 2 ))
  done
}

# IMDSv2
imds() {
  local token
  token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300') &&
  curl -fsS -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$1"
}

get_param()  { aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text; }
get_secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
get_tag() {
  aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=$1" \
    --query 'Tags[0].Value' --output text
}

# ---------------------------------------------------------------------------
# Failure / success handling
# ---------------------------------------------------------------------------
FAILED_LINE="" FAILED_CMD="" INSTANCE_ID="" ASG_NAME=""
trap 'FAILED_LINE=$LINENO; FAILED_CMD=$BASH_COMMAND' ERR

lifecycle() {   # $1 = CONTINUE or ABANDON
  [[ -n "$LIFECYCLE_HOOK" && -n "$ASG_NAME" && "$ASG_NAME" != None ]] || return 0
  aws autoscaling complete-lifecycle-action \
    --lifecycle-hook-name "$LIFECYCLE_HOOK" --auto-scaling-group-name "$ASG_NAME" \
    --instance-id "$INSTANCE_ID" --lifecycle-action-result "$1"
}

on_exit() {
  local rc=$?
  set +e   # never let the cleanup itself abort halfway
  if (( rc == 0 )); then
    echo "=== user-data SUCCEEDED $(date -Is) ==="
    return
  fi
  local msg="user-data FAILED on ${INSTANCE_ID:-$(hostname)} (exit $rc) at line ${FAILED_LINE:-?}: ${FAILED_CMD:-?}"
  echo "=== $msg ==="
  [[ -n "$SNS_TOPIC_ARN" ]] && aws sns publish --topic-arn "$SNS_TOPIC_ARN" \
    --subject "$APP bootstrap failed" --message "$msg"
  [[ -n "$INSTANCE_ID" ]] && aws ec2 create-tags --resources "$INSTANCE_ID" \
    --tags Key=bootstrap,Value=FAILED
  lifecycle ABANDON
  if [[ "$SHUTDOWN_ON_FAILURE" == true ]]; then
    sync
    shutdown -h now
  fi
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Who / where am I
# ---------------------------------------------------------------------------
INSTANCE_ID=$(retry 5 imds instance-id)
AWS_DEFAULT_REGION=$(retry 5 imds placement/region)
export AWS_DEFAULT_REGION

ENV=$(retry 5 get_tag Environment)                     # e.g. dev / test / prod
ASG_NAME=$(retry 5 get_tag aws:autoscaling:groupName)  # "None" if not in an ASG
[[ "$ENV" != None ]] || { log "instance has no Environment tag"; exit 1; }
log "instance=$INSTANCE_ID region=$AWS_DEFAULT_REGION env=$ENV asg=$ASG_NAME"

# ---------------------------------------------------------------------------
# 1. Per-environment config from Parameter Store / Secrets Manager
# ---------------------------------------------------------------------------
PREFIX="/$APP/$ENV"
DOMAIN=$(retry 5 get_param "$PREFIX/domain")
EFS_ID=$(retry 5 get_param "$PREFIX/efs_id")
API_ENDPOINT=$(retry 5 get_param "$PREFIX/api_endpoint")
JOIN_USER=$(retry 5 get_param "$PREFIX/domain_join_user")
export ENV DOMAIN EFS_ID API_ENDPOINT

# Render config templates baked into the AMI (e.g. /etc/myapp/app.conf.tmpl).
# Only the listed variables are substituted, so other $ signs are left alone.
for tmpl in /etc/"$APP"/*.tmpl; do
  [[ -e "$tmpl" ]] || continue
  envsubst '$ENV $DOMAIN $EFS_ID $API_ENDPOINT' < "$tmpl" > "${tmpl%.tmpl}"
  log "rendered ${tmpl%.tmpl}"
done

# ---------------------------------------------------------------------------
# 2. EFS (amazon-efs-utils baked in). fstab makes it survive reboots;
#    nofail keeps a missing mount from hanging boot.
# ---------------------------------------------------------------------------
mkdir -p "$EFS_MOUNT"
grep -q " $EFS_MOUNT efs " /etc/fstab ||
  echo "$EFS_ID:/ $EFS_MOUNT efs _netdev,tls,nofail 0 0" >> /etc/fstab

mount_efs() { mountpoint -q "$EFS_MOUNT" || mount "$EFS_MOUNT"; }
retry 8 mount_efs

# ---------------------------------------------------------------------------
# 3. Domain join with SSSD (realmd + sssd baked in)
# ---------------------------------------------------------------------------
retry 10 host -t SRV "_ldap._tcp.$DOMAIN"    # wait until the DCs resolve

join_domain() {
  realm list --name-only | grep -qix "$DOMAIN" && return 0   # already joined
  get_secret "$PREFIX/domain_join_password" | realm join -U "$JOIN_USER" "$DOMAIN"
}
retry 5 join_domain
systemctl enable --now sssd

# ---------------------------------------------------------------------------
# 4. Local user passwords. Secret is JSON: {"user1": "pw1", "user2": "pw2"}
#    Nothing is echoed, so passwords never reach the log.
# ---------------------------------------------------------------------------
set_passwords() {
  get_secret "$PREFIX/local_passwords" |
    jq -r 'to_entries[] | "\(.key):\(.value)"' |
    chpasswd
}
retry 5 set_passwords

# ---------------------------------------------------------------------------
# 5. Start the app
# ---------------------------------------------------------------------------
systemctl enable --now "$APP"

# ---------------------------------------------------------------------------
# 6. Validate. This is what catches "it ran but the box is unusable".
#    Any failing check exits non-zero and the EXIT trap takes over.
# ---------------------------------------------------------------------------
log "validating"
mountpoint -q "$EFS_MOUNT"
TEST_USER=$(retry 3 get_param "$PREFIX/test_domain_user")
retry 5 id "$TEST_USER"                       # proves SSSD + the domain join work
systemctl is-active --quiet sssd
systemctl is-active --quiet "$APP"
retry 5 curl -fsS -o /dev/null "$API_ENDPOINT/health"

# ---------------------------------------------------------------------------
# Success
# ---------------------------------------------------------------------------
aws ec2 create-tags --resources "$INSTANCE_ID" --tags Key=bootstrap,Value=OK
lifecycle CONTINUE
