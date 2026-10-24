# Inspector report exports require a customer-managed KMS key.
# The AWS-managed aws/s3 key will not work because its policy cannot be edited.

data "aws_iam_policy_document" "report_key" {
  statement {
    sid       = "EnableAccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowInspectorReportExport"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["inspector2.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:inspector2:${var.aws_region}:${local.account_id}:report/*"]
    }
  }
}

resource "aws_kms_key" "report" {
  description             = "Encrypts Inspector findings report exports"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.report_key.json
}

resource "aws_kms_alias" "report" {
  name          = "alias/${var.project_name}-report"
  target_key_id = aws_kms_key.report.key_id
}

resource "aws_s3_bucket" "report" {
  bucket        = "${var.project_name}-reports-${local.account_id}-${var.aws_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "report" {
  bucket                  = aws_s3_bucket.report.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "report" {
  bucket = aws_s3_bucket.report.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.report.arn
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "report_bucket" {
  statement {
    sid       = "AllowInspectorReportWrite"
    actions   = ["s3:PutObject", "s3:PutObjectAcl", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.report.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["inspector2.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:inspector2:${var.aws_region}:${local.account_id}:report/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "report" {
  bucket = aws_s3_bucket.report.id
  policy = data.aws_iam_policy_document.report_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.report]
}
