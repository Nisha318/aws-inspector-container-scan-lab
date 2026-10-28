# Optional: a read-only role that a delivery repository's workflow assumes
# through OIDC to download the scheduled findings reports from S3.
#
# Works with github.com or a GitHub Enterprise Server instance. The OIDC provider
# must already exist in the account. This file looks it up by URL and never
# creates it. For github.com, github_oidc.tf creates it.
#
# Leave var.delivery_repo empty to skip every resource in this file.

variable "delivery_repo" {
  description = "Repository in ORG/REPO form whose workflow may download reports, for example cyber/team-a-findings. Leave empty to skip."
  type        = string
  default     = ""

  validation {
    condition     = var.delivery_repo == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.delivery_repo))
    error_message = "delivery_repo must look like ORG/REPO."
  }
}

variable "delivery_oidc_url" {
  description = <<-EOT
    URL of the IAM OIDC provider that issues the delivery repo's tokens.
    github.com:  https://token.actions.githubusercontent.com
    GHES:        https://YOUR-GHES-HOST/_services/token
  EOT
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

variable "delivery_audience" {
  description = "Audience the workflow requests. Must appear in the provider's client ID list."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "delivery_branch" {
  description = "Branch the delivery workflow runs from. The role only trusts tokens from this branch."
  type        = string
  default     = "main"
}

variable "delivery_subject_override" {
  description = <<-EOT
    Exact token subject values to trust, replacing the default repo-and-branch value.
    Use it when the subject differs from repo:ORG/REPO:ref:refs/heads/BRANCH, for example
    a customized subject template on GHES, or the immutable format on a github.com repo
    created after July 15, 2026. Print the real subject from a workflow run to find it.
  EOT
  type        = list(string)
  default     = []
}

locals {
  delivery_enabled   = var.delivery_repo != ""
  delivery_oidc_host = trimprefix(var.delivery_oidc_url, "https://")
  delivery_subjects = (
    length(var.delivery_subject_override) > 0
    ? var.delivery_subject_override
    : ["repo:${var.delivery_repo}:ref:refs/heads/${var.delivery_branch}"]
  )
}

data "aws_iam_openid_connect_provider" "delivery" {
  count = local.delivery_enabled ? 1 : 0

  url = var.delivery_oidc_url
}

data "aws_iam_policy_document" "delivery_trust" {
  count = local.delivery_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [one(data.aws_iam_openid_connect_provider.delivery[*].arn)]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.delivery_oidc_host}:aud"
      values   = [var.delivery_audience]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.delivery_oidc_host}:sub"
      values   = local.delivery_subjects
    }
  }
}

data "aws_iam_policy_document" "delivery_read" {
  count = local.delivery_enabled ? 1 : 0

  statement {
    sid       = "ListThisCustomersReports"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.report.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["exports/${var.export_customer}/*"]
    }
  }

  statement {
    sid       = "ReadThisCustomersReports"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.report.arn}/exports/${var.export_customer}/*"]
  }

  # The reports are encrypted with the lab key. The key policy already lets
  # IAM policies in this account grant access, so this statement is enough.
  statement {
    sid       = "DecryptReports"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.report.arn]
  }
}

resource "aws_iam_role" "delivery" {
  count = local.delivery_enabled ? 1 : 0

  name               = "${var.project_name}-report-delivery"
  assume_role_policy = data.aws_iam_policy_document.delivery_trust[0].json
}

resource "aws_iam_role_policy" "delivery" {
  count = local.delivery_enabled ? 1 : 0

  name   = "read-customer-reports"
  role   = aws_iam_role.delivery[0].id
  policy = data.aws_iam_policy_document.delivery_read[0].json
}

output "delivery_role_arn" {
  description = "Save this as a variable in the delivery repo for its workflow to assume. Null when delivery_repo is empty."
  value       = one(aws_iam_role.delivery[*].arn)
}
