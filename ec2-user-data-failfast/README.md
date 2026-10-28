# EC2 user-data that fails loudly

Bootstrap pattern for EC2 instances whose user-data sometimes fails partway,
leaving an instance that looks fine in the console but isn't usable.

The goal: a failed bootstrap is **noticed** (alert, tag), **taken out of
service** (stopped, or replaced by the ASG), and still **debuggable** (logs and
disk kept).

[`user-data.sh`](user-data.sh) is a working template: Parameter Store config,
templated config files, EFS mount, SSSD domain join, local passwords, a
validation block, and the failure handling below.

## 1. Fail fast

```bash
set -Eeuo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1
```

| Flag | Stops the script on |
|---|---|
| `-e` | any failed command |
| `-u` | an unset variable |
| `-o pipefail` | a failure anywhere in a pipe |
| `-E` | (makes the ERR trap fire inside functions too) |

Commands that are allowed to fail need `|| true`.

## 2. Do something on failure

An `EXIT` trap catches every way the script can die (an `ERR` trap misses
`set -u` exits). An `ERR` trap alongside it records the failing line and
command for the message:

```bash
trap 'FAILED_LINE=$LINENO; FAILED_CMD=$BASH_COMMAND' ERR
on_exit() {
  rc=$?; set +e
  (( rc == 0 )) && return
  aws sns publish ...              # alert
  aws ec2 create-tags ... bootstrap=FAILED
  complete-lifecycle-action ... ABANDON   # if in an ASG with a hook
  sync; shutdown -h now
}
trap on_exit EXIT
```

What to do on failure, depending on setup:

- **Stand-alone instance:** `shutdown -h now`. A stopped instance is obvious in
  the console and keeps its disk. User-data only runs on first boot, so starting
  it again to read the logs won't re-run the script.
- **Auto Scaling group:** `ABANDON` the lifecycle hook, or
  `aws autoscaling set-instance-health --health-status Unhealthy`. The ASG
  terminates it and launches a replacement, which often succeeds when the cause
  was timing.
- **Behind a load balancer:** only make the health check pass once the script
  finishes, so a half-built instance never gets traffic.
- **Always:** tag it (`bootstrap=FAILED` / `OK`) so failures are easy to filter.

Avoid breaking SSH or networking on purpose: it does make the instance look
broken, but then you can't get in to see why it failed.

## 3. Retry the flaky steps

Most "random" failures are timing: DNS not ready, EFS mount target not
resolvable yet, domain controllers unreachable, package locks, API throttling.

```bash
# usage: retry <attempts> <command...>
retry() {
  local max=$1; shift
  local n=1 delay=5
  until "$@"; do
    if (( n >= max )); then echo "FAILED after $n attempts: $*" >&2; return 1; fi
    echo "attempt $n failed: $*  (retrying in ${delay}s)" >&2
    sleep "$delay"; n=$(( n + 1 ))
    delay=$(( delay * 2 > 60 ? 60 : delay * 2 ))
  done
}

retry 10 host -t SRV "_ldap._tcp.$DOMAIN"
DB=$(retry 5 aws ssm get-parameter --name "/myapp/$ENV/db" --query Parameter.Value --output text)
```

- Messages go to stderr so `$(...)` captures only the command's output.
- When all attempts fail, `retry` returns 1, `set -e` exits, and the trap runs.
- Multi-step work goes in a function: `retry 5 join_domain`.
- **Gotcha:** bash ignores `set -e` inside a function that's called from a
  condition (which `until "$@"` is). Inside retried functions, chain with `&&`
  or `return` explicitly, otherwise an early failure is silently skipped.
- Don't put `$(...)` inside another command's arguments
  (`id "$(get_param x)"`): a failure there doesn't trigger `set -e`. Assign to a
  variable first.
- Keep total retry time under the ASG health check grace period or lifecycle
  hook timeout.

## 4. Make steps idempotent

So a retry, or a re-run, doesn't break things:

```bash
grep -q " /mnt/efs efs " /etc/fstab || echo "$EFS_ID:/ /mnt/efs efs _netdev,tls,nofail 0 0" >> /etc/fstab
mountpoint -q /mnt/efs || mount /mnt/efs
realm list --name-only | grep -qix "$DOMAIN" || realm join ...
```

## 5. Validate before declaring success

This catches "the script ran but the box is unusable":

```bash
mountpoint -q /mnt/efs
id someuser@corp.example.com      # SSSD + domain join actually work
systemctl is-active --quiet sssd myapp
curl -fsS "$API_ENDPOINT/health"
```

Only after these pass: tag `bootstrap=OK` and lifecycle `CONTINUE`.

## 6. Bake what's the same everywhere

Use Packer or EC2 Image Builder to put packages, agents, `amazon-efs-utils`,
`sssd`/`realmd`, `jq` and config **templates** in the AMI. User-data then only
does per-environment and per-instance work, which removes most of the flaky
steps (package installs, downloads) from boot.

Per-environment values live outside the AMI:

| What | Where |
|---|---|
| Endpoints, EFS ID, domain, account-specific settings | SSM Parameter Store, `/myapp/<env>/...` |
| Domain join password, local user passwords | Secrets Manager |
| Which environment this instance is in | Instance tag, e.g. `Environment=prod` |

Templates are rendered with `envsubst`, listing the variables explicitly so
other `$` signs in config files are left alone:

```bash
envsubst '$ENV $DOMAIN $API_ENDPOINT' < /etc/myapp/app.conf.tmpl > /etc/myapp/app.conf
```

## 7. Alert on patterns, not just single failures

- SNS from the trap for each failure.
- CloudWatch agent shipping `/var/log/user-data.log` and
  `/var/log/cloud-init-output.log`, with a metric filter on `FAILED` and an alarm.
- With an ASG: alarm on abandoned lifecycle actions or launch/terminate churn.
  A bad AMI or bad parameter shows up as a spike.

## Going further: SSM State Manager

Many teams move ongoing configuration (domain join, passwords, config files)
out of user-data into SSM State Manager associations or Ansible run through
SSM. User-data just makes sure the SSM agent is running. You get per-step logs
in the console, compliance status per instance, and can re-apply config without
relaunching.

## Using the template

1. Bake the AMI with: `awscli`, `jq`, `gettext` (`envsubst`), `bind-utils` /
   `dnsutils` (`host`), `amazon-efs-utils`, `realmd`, `sssd`, `adcli`, your app,
   and templates in `/etc/myapp/*.tmpl`.
2. Create parameters under `/myapp/<env>/`: `domain`, `efs_id`, `api_endpoint`,
   `domain_join_user`, `test_domain_user`. Secrets: `/myapp/<env>/domain_join_password`
   and `/myapp/<env>/local_passwords` (JSON `{"user": "password"}`).
3. Tag instances (or the launch template) with `Environment=<env>`.
4. Fill in the settings at the top of the script (`SNS_TOPIC_ARN`, `LIFECYCLE_HOOK`).
5. Instance role permissions:
   - `ssm:GetParameter`, `secretsmanager:GetSecretValue` (plus `kms:Decrypt` for
     SecureString / customer-managed keys), scoped to `/myapp/*`
   - `ec2:DescribeTags`, `ec2:CreateTags`
   - `sns:Publish` on the topic
   - `autoscaling:CompleteLifecycleAction` (if using a hook)
6. Test the failure path once: add `false` partway through and confirm the
   instance is tagged, alerted on, and stopped (or replaced).
