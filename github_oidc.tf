# Optional: lets the push-images GitHub Actions workflow authenticate to AWS
# with OIDC instead of long-lived access keys.
#
# Leave var.github_repo empty to skip every resource in this file and use
# scripts/push-images.sh instead. Delete the file entirely if you never want it.

variable "github_repo" {
  description = "GitHub repository in owner/name form that may push images through the Actions workflow. Leave empty to skip the GitHub Actions resources."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repo == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name, for example jane-doe/aws-inspector-container-scan-lab."
  }
}

variable "create_github_oidc_provider" {
  description = "Set to false if this account already has the GitHub OIDC provider. AWS allows only one per account."
  type        = bool
  default     = true
}

variable "github_branch" {
  description = "Branch the workflow runs from. The IAM trust policy only accepts tokens from this branch."
  type        = string
  default     = "main"
}

locals {
  enable_github = var.github_repo != ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.enable_github && var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS no longer validates thumbprints for GitHub, but older provider
  # versions still require the argument to be present.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_openid_connect_provider" "github" {
  count = local.enable_github && !var.create_github_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_trust" {
  count = local.enable_github ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        coalesce(
          one(aws_iam_openid_connect_provider.github[*].arn),
          one(data.aws_iam_openid_connect_provider.github[*].arn),
        )
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

data "aws_iam_policy_document" "github_push" {
  count = local.enable_github ? 1 : 0

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushToLabRepositories"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [for repo in aws_ecr_repository.lab : repo.arn]
  }
}

resource "aws_iam_role" "github_actions" {
  count = local.enable_github ? 1 : 0

  name               = "${var.project_name}-github-actions-push"
  assume_role_policy = data.aws_iam_policy_document.github_trust[0].json
}

resource "aws_iam_role_policy" "github_actions" {
  count = local.enable_github ? 1 : 0

  name   = "push-lab-images"
  role   = aws_iam_role.github_actions[0].id
  policy = data.aws_iam_policy_document.github_push[0].json
}

output "github_actions_role_arn" {
  description = "Save this as the AWS_ROLE_ARN repository variable in GitHub. Null when github_repo is empty."
  value       = one(aws_iam_role.github_actions[*].arn)
}
