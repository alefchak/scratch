# ansible

## rotate-root.yml

Rotates the root password on Linux hosts and stores each new password in
AWS Secrets Manager, without a window where the only working copy could be lost.

Per host:

1. Saves the current `/etc/shadow` hash, so rollback never needs the old plaintext.
2. Generates a password that meets the length, character-class and
   max-class-repeat rules, and hashes it once.
3. Writes it to Secrets Manager as `AWSPENDING` and reads it back. `AWSCURRENT` is untouched.
4. Sets the hash on the host and checks `/etc/shadow` matches.
5. Promotes `AWSPENDING` to `AWSCURRENT`. AWS moves the old version to `AWSPREVIOUS`.

If any step fails, `AWSPENDING` is cleared and the old hash is restored on the
host, so the host and `AWSCURRENT` stay on the old password. The one exception:
if the new version already became `AWSCURRENT` (say the promote call succeeded
but its reply was lost), the host keeps the new password to match.
Hosts run one canary first, then 5, then 20% at a time, stopping at the first failure.

No published Ansible module can set Secrets Manager staging labels, so the AWS
calls go through [`library/secretsmanager_stage.py`](library/secretsmanager_stage.py),
a small module in this repo built on the `amazon.aws` helpers. It takes the
usual `region`, `profile` and credential options. CI tests it against a local
[moto](https://github.com/getmoto/moto) server
([`tests/test_secretsmanager_stage.yml`](tests/test_secretsmanager_stage.yml)).

### rotate-root-awscli.yml

The same flow, calling the AWS CLI through `ansible.builtin.command` instead of
the custom module. The new password is passed to the CLI through a temporary
`0600` file, so it never appears in the process list. It needs the AWS CLI on
the controller, but no code of your own to maintain. The assumptions and
requirements below apply to both playbooks.

### Assumptions

- One secret per host named `root/<inventory_hostname>`, holding a plain string.
  Change `secret_id` in the playbook if yours differ, and adapt the put and
  read-back steps if the secret holds JSON.
- No rotation Lambda is configured on these secrets.
- Ansible connects with an SSH key and sudo, not the root password.

### Controller requirements

- Collections: `ansible-galaxy collection install -r requirements.yml`
- `boto3`/`botocore`, and `passlib` (used by `password_hash`)
- For `rotate-root-awscli.yml` only: the AWS CLI
- AWS credentials and region from the environment or a profile, with
  `secretsmanager:DescribeSecret`, `GetSecretValue`, `PutSecretValue` and
  `UpdateSecretVersionStage` on the secrets

### Running

```sh
cp inventory.example.ini inventory.ini   # then edit
ansible-playbook -i inventory.ini rotate-root.yml --limit <test-host>   # first, on a host with console access
ansible-playbook -i inventory.ini rotate-root.yml
```

Tune the password rules in the "Generate compliant password" task
(`length`, `min_*`, `override_special`) and `max_class_repeat` in `vars`.
