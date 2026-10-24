output "aws_region" {
  value = var.aws_region
}

output "account_id" {
  value = local.account_id
}

output "ecr_repository_urls" {
  description = "Push targets for the next step of the walkthrough."
  value       = { for name, repo in aws_ecr_repository.lab : name => repo.repository_url }
}

output "report_bucket" {
  description = "S3 bucket that receives the Inspector findings export."
  value       = aws_s3_bucket.report.id
}

output "report_kms_key_arn" {
  description = "KMS key ARN to supply when you export the findings report."
  value       = aws_kms_key.report.arn
}
