# Optional: email notifications for the delivery step.
#
# Two SNS topics with two audiences:
#
#   delivery  The people who read the reports. The delivery workflow publishes
#             here after it commits new reports, with a link to the dated folder.
#             Nothing is sent when a run finds nothing new.
#
#   ops       The team that runs the pipeline. Receives a message when the
#             scheduled export fails (the dead-letter queue gets a message) or
#             when the delivery workflow fails. Silence means everything ran.
#
# Each topic is created only when its email list is not empty. Every address
# receives a confirmation email from AWS and must click the link before any
# notification arrives. Terraform cannot confirm subscriptions on anyone's behalf.
#
# The topics are not encrypted with a customer-managed key. Messages carry a
# repository URL, a folder name, and file names, never finding data. CloudWatch
# alarms cannot publish to a topic encrypted with the AWS-managed SNS key, and a
# customer-managed key would add a key policy for information this plain.

variable "delivery_notify_emails" {
  description = "Email addresses told when new reports land in the delivery repository. Empty disables the delivery topic."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.delivery_notify_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every entry in delivery_notify_emails must be an email address."
  }
}

variable "ops_notify_emails" {
  description = "Email addresses told when the export or the delivery fails. Empty disables the ops topic and the dead-letter queue alarm."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.ops_notify_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every entry in ops_notify_emails must be an email address."
  }
}

locals {
  notify_delivery = local.delivery_enabled && length(var.delivery_notify_emails) > 0
  notify_ops      = length(var.ops_notify_emails) > 0
}

# --- Delivery topic: "new reports are in the repository" ---------------------

resource "aws_sns_topic" "delivery" {
  count = local.notify_delivery ? 1 : 0

  name = "${var.project_name}-report-delivered"
}

resource "aws_sns_topic_subscription" "delivery" {
  for_each = local.notify_delivery ? toset(var.delivery_notify_emails) : toset([])

  topic_arn = aws_sns_topic.delivery[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Ops topic: "something failed" --------------------------------------------

resource "aws_sns_topic" "ops" {
  count = local.notify_ops ? 1 : 0

  name = "${var.project_name}-report-pipeline-failures"
}

resource "aws_sns_topic_subscription" "ops" {
  for_each = local.notify_ops ? toset(var.ops_notify_emails) : toset([])

  topic_arn = aws_sns_topic.ops[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# Scheduler drops a message in the dead-letter queue when an export run fails
# after its retries. SQS reports the visible message count to CloudWatch, so a
# count of one or more is the signal. The alarm clears itself once the queue is
# emptied. Same-account alarms may publish to the topic under its default policy.
resource "aws_cloudwatch_metric_alarm" "export_failures" {
  count = local.notify_ops && local.enable_scheduled_export ? 1 : 0

  alarm_name        = "${var.project_name}-export-failed"
  alarm_description = "A scheduled Inspector findings export failed. Read the message in the ${aws_sqs_queue.export_dlq[0].name} queue for the error."

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.export_dlq[0].name
  }

  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops[0].arn]
  ok_actions    = [aws_sns_topic.ops[0].arn]
}

# --- Let the delivery workflow publish -----------------------------------------

# A second inline policy on the delivery role, so delivery_role.tf keeps its
# read-only shape and this file owns everything about notifications. The role
# may publish to these two topics and nothing else in SNS.
data "aws_iam_policy_document" "delivery_notify" {
  count = local.delivery_enabled && (local.notify_delivery || local.notify_ops) ? 1 : 0

  statement {
    sid     = "PublishDeliveryNotifications"
    actions = ["sns:Publish"]
    resources = compact([
      one(aws_sns_topic.delivery[*].arn),
      one(aws_sns_topic.ops[*].arn),
    ])
  }
}

resource "aws_iam_role_policy" "delivery_notify" {
  count = local.delivery_enabled && (local.notify_delivery || local.notify_ops) ? 1 : 0

  name   = "publish-delivery-notifications"
  role   = aws_iam_role.delivery[0].id
  policy = data.aws_iam_policy_document.delivery_notify[0].json
}

output "delivery_topic_arn" {
  description = "Save this as the DELIVERY_TOPIC_ARN variable in the delivery repository. Null when delivery_notify_emails is empty."
  value       = one(aws_sns_topic.delivery[*].arn)
}

output "ops_topic_arn" {
  description = "Save this as the OPS_TOPIC_ARN variable in the delivery repository. Null when ops_notify_emails is empty."
  value       = one(aws_sns_topic.ops[*].arn)
}
