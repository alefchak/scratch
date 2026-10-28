terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "loki_bucket" {
  type        = string
  description = "Name of the existing Loki S3 bucket"
}

variable "loki_role_name" {
  type        = string
  description = "Name of the IAM role Loki uses to access the bucket (e.g. its IRSA role)"
}

variable "noncurrent_days" {
  type        = number
  default     = 30
  description = "How long deleted/overwritten objects stay recoverable"
}

data "aws_s3_bucket" "loki" {
  bucket = var.loki_bucket
}

# Keep previous versions of every object, so deletes leave a recoverable delete marker.
resource "aws_s3_bucket_versioning" "loki" {
  bucket = var.loki_bucket

  versioning_configuration {
    status = "Enabled"
  }
}

# NOTE: this resource owns the bucket's ENTIRE lifecycle configuration.
# If the bucket already has lifecycle rules, copy them in as extra rule blocks.
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket     = var.loki_bucket
  depends_on = [aws_s3_bucket_versioning.loki]

  rule {
    id     = "keep-deleted-loki-objects"
    status = "Enabled"
    filter {}

    # Deleted or overwritten objects stay recoverable for this long
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }

    # Clean up delete markers once nothing is left behind them
    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Loki only ever does plain deletes (which leave a delete marker), so it never needs to
# purge object versions. An explicit Deny means nothing running as Loki can permanently
# erase data, even if the role is later granted broader S3 permissions.
data "aws_iam_policy_document" "loki_deny_version_purge" {
  statement {
    sid    = "DenyPermanentDeletes"
    effect = "Deny"
    actions = [
      "s3:DeleteObjectVersion",
    ]
    resources = ["${data.aws_s3_bucket.loki.arn}/*"]
  }
}

resource "aws_iam_role_policy" "loki_deny_version_purge" {
  name   = "deny-loki-bucket-version-purge"
  role   = var.loki_role_name
  policy = data.aws_iam_policy_document.loki_deny_version_purge.json
}
