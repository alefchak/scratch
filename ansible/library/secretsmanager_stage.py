#!/usr/bin/python
# -*- coding: utf-8 -*-

DOCUMENTATION = r"""
---
module: secretsmanager_stage
short_description: Stage, promote and clear AWS Secrets Manager versions
description:
  - Writes a new secret version under the C(AWSPENDING) label without touching
    C(AWSCURRENT), promotes a version to C(AWSCURRENT), or clears C(AWSPENDING).
  - Fills the gap left by C(community.aws.secretsmanager_secret), which always
    writes straight to C(AWSCURRENT).
options:
  secret_id:
    description: Name or ARN of an existing secret.
    type: str
    required: true
  action:
    description:
      - C(put_pending) writes I(secret_string) as a new version labelled C(AWSPENDING).
      - C(promote) moves C(AWSCURRENT) to I(version_id), then removes C(AWSPENDING) from it.
        AWS moves C(AWSPREVIOUS) to the old current version automatically.
      - C(clear_pending) removes C(AWSPENDING) from I(version_id) if present, and reports
        whether that version is C(AWSCURRENT).
    type: str
    required: true
    choices: [put_pending, promote, clear_pending]
  secret_string:
    description: Value to store. Required for C(put_pending).
    type: str
  version_id:
    description: Version to act on. Required for C(promote) and C(clear_pending).
    type: str
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
"""

RETURN = r"""
version_id:
  description: The version written (put_pending) or acted on.
  type: str
  returned: always
previous_version_id:
  description: The version that was AWSCURRENT before a promote.
  type: str
  returned: when action is promote
is_current:
  description: Whether I(version_id) holds AWSCURRENT after the action.
  type: bool
  returned: always
version_ids_to_stages:
  description: Map of version IDs to their labels after the action. Contains no secret values.
  type: dict
  returned: always
"""

import uuid

try:
    import botocore
except ImportError:
    pass  # handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry


def stages(client, secret_id):
    desc = client.describe_secret(SecretId=secret_id, aws_retry=True)
    return desc.get("VersionIdsToStages", {})


def current_of(vmap):
    for vid, labels in vmap.items():
        if "AWSCURRENT" in labels:
            return vid
    return None


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            secret_id=dict(type="str", required=True),
            action=dict(type="str", required=True, choices=["put_pending", "promote", "clear_pending"]),
            secret_string=dict(type="str", no_log=True),
            version_id=dict(type="str"),
        ),
        required_if=[
            ("action", "put_pending", ["secret_string"]),
            ("action", "promote", ["version_id"]),
            ("action", "clear_pending", ["version_id"]),
        ],
        supports_check_mode=True,
    )
    p = module.params
    sid = p["secret_id"]
    client = module.client("secretsmanager", retry_decorator=AWSRetry.jittered_backoff())

    try:
        vmap = stages(client, sid)
        result = dict(changed=False, previous_version_id=None)

        if p["action"] == "put_pending":
            if module.check_mode:
                module.exit_json(changed=True, version_id=None, is_current=False, version_ids_to_stages=vmap)
            token = str(uuid.uuid4())
            resp = client.put_secret_value(
                SecretId=sid,
                SecretString=p["secret_string"],
                ClientRequestToken=token,
                VersionStages=["AWSPENDING"],
                aws_retry=True,
            )
            result.update(changed=True, version_id=resp["VersionId"])

        elif p["action"] == "promote":
            vid = p["version_id"]
            if vid not in vmap:
                module.fail_json(msg="Version %s not found on secret %s" % (vid, sid))
            old = current_of(vmap)
            result.update(version_id=vid, previous_version_id=old)
            if old != vid:
                result["changed"] = True
                if not module.check_mode:
                    kwargs = dict(SecretId=sid, VersionStage="AWSCURRENT", MoveToVersionId=vid, aws_retry=True)
                    if old:
                        kwargs["RemoveFromVersionId"] = old
                    client.update_secret_version_stage(**kwargs)
            # Clearing the label is cosmetic once AWSCURRENT has moved: never fail on it,
            # or the playbook would roll the host back while the secret is already new.
            if "AWSPENDING" in vmap.get(vid, []) and not module.check_mode:
                try:
                    client.update_secret_version_stage(
                        SecretId=sid, VersionStage="AWSPENDING", RemoveFromVersionId=vid, aws_retry=True
                    )
                    result["changed"] = True
                except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
                    module.warn("Promoted, but could not clear AWSPENDING: %s" % e)

        elif p["action"] == "clear_pending":
            vid = p["version_id"]
            result["version_id"] = vid
            if "AWSPENDING" in vmap.get(vid, []):
                result["changed"] = True
                if not module.check_mode:
                    client.update_secret_version_stage(
                        SecretId=sid, VersionStage="AWSPENDING", RemoveFromVersionId=vid, aws_retry=True
                    )

        vmap = stages(client, sid) if not module.check_mode else vmap
        result["version_ids_to_stages"] = vmap
        result["is_current"] = "AWSCURRENT" in vmap.get(result["version_id"], [])
        module.exit_json(**result)

    except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
        module.fail_json_aws(e, msg="Secrets Manager %s failed for %s" % (p["action"], sid))


if __name__ == "__main__":
    main()
