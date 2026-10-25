# Optional: exports Inspector findings to the report bucket on a schedule.
#
# EventBridge Scheduler calls the Inspector CreateFindingsReport API directly
# (a "universal target"), so no Lambda function or code is involved. Inspector
# writes the file itself, using the bucket and key policies in storage.tf.
#
# Leave var.export_schedule empty to skip every resource in this file.

variable "export_schedule" {
  description = <<-EOT
    Schedule for the findings export, or empty to disable.
    Recurring example:  cron(0 6 * * ? *)   daily at 06:00 in export_schedule_timezone
    One-time test run:  at(2026-10-25T09:00:00)
  EOT
  type        = string
  default     = ""
}

variable "export_schedule_timezone" {
  description = "IANA time zone the schedule expression is evaluated in."
  type        = string
  default     = "UTC"
}

variable "export_customer" {
  description = "Short name for the customer or team. Reports land under exports/<name>/ in the bucket."
  type        = string
  default     = "lab"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.export_customer))
    error_message = "export_customer must use lowercase letters, digits, and hyphens only."
  }
}

variable "export_report_format" {
  description = "CSV or JSON."
  type        = string
  default     = "CSV"

  validation {
    condition     = contains(["CSV", "JSON"], var.export_report_format)
    error_message = "export_report_format must be CSV or JSON."
  }
}

locals {
  enable_scheduled_export = var.export_schedule != ""
}

data "aws_iam_policy_document" "export_scheduler_trust" {
  count = local.enable_scheduled_export ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "export_scheduler" {
  count = local.enable_scheduled_export ? 1 : 0

  statement {
    sid       = "RequestFindingsReport"
    actions   = ["inspector2:CreateFindingsReport"]
    resources = ["*"]
  }

  statement {
    sid       = "ReportFailuresToDeadLetterQueue"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.export_dlq[0].arn]
  }
}

# Without this queue a failed run leaves no trace. When the schedule cannot
# complete the call, Scheduler drops the event here with the error attached.
resource "aws_sqs_queue" "export_dlq" {
  count = local.enable_scheduled_export ? 1 : 0

  name                      = "${var.project_name}-export-failures"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_iam_role" "export_scheduler" {
  count = local.enable_scheduled_export ? 1 : 0

  name               = "${var.project_name}-export-scheduler"
  assume_role_policy = data.aws_iam_policy_document.export_scheduler_trust[0].json
}

resource "aws_iam_role_policy" "export_scheduler" {
  count = local.enable_scheduled_export ? 1 : 0

  name   = "request-findings-report"
  role   = aws_iam_role.export_scheduler[0].id
  policy = data.aws_iam_policy_document.export_scheduler[0].json
}

resource "aws_scheduler_schedule" "export" {
  count = local.enable_scheduled_export ? 1 : 0

  name                         = "${var.project_name}-findings-export"
  schedule_expression          = var.export_schedule
  schedule_expression_timezone = var.export_schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:inspector2:createFindingsReport"
    role_arn = aws_iam_role.export_scheduler[0].arn

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }

    dead_letter_config {
      arn = aws_sqs_queue.export_dlq[0].arn
    }

    # Parameter names follow the Inspector API in PascalCase. The filter limits
    # the report to active findings on this customer's repositories.
    input = jsonencode({
      ReportFormat = var.export_report_format
      S3Destination = {
        BucketName = aws_s3_bucket.report.id
        KeyPrefix  = "exports/${var.export_customer}"
        KmsKeyArn  = aws_kms_key.report.arn
      }
      FilterCriteria = {
        EcrImageRepositoryName = [{ Comparison = "PREFIX", Value = "${var.project_name}/" }]
        FindingStatus          = [{ Comparison = "EQUALS", Value = "ACTIVE" }]
      }
    })
  }
}

output "export_failure_queue_url" {
  description = "Check this queue when a scheduled export produces no report. Null when export_schedule is empty."
  value       = one(aws_sqs_queue.export_dlq[*].url)
}

output "scheduled_export_prefix" {
  description = "Where scheduled reports land. Null when export_schedule is empty."
  value       = local.enable_scheduled_export ? "s3://${aws_s3_bucket.report.id}/exports/${var.export_customer}/" : null
}
