variable "aws_region" {
  description = "Region to deploy into. Inspector and the report bucket must share a region."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for resource names and tags."
  type        = string
  default     = "inspector-lab"
}

variable "manage_inspector" {
  description = <<-EOT
    Whether Terraform enables Inspector for ECR and sets enhanced registry scanning.

    Both settings apply to the whole account and region, and terraform destroy
    reverses them. Check first:
      aws inspector2 batch-get-account-status
      aws ecr get-registry-scanning-configuration

    Leave true if ECR shows DISABLED and the scan type is BASIC (a clean account).
    Set false if ECR is already ENABLED, so destroy cannot switch off scanning
    that other workloads rely on. With false, Inspector must already be enabled
    for ECR and the registry must already use ENHANCED scanning, or the lab
    produces no findings.
  EOT
  type        = bool
  default     = true
}

variable "image_repositories" {
  description = "ECR repositories to create. You push intentionally outdated images into these in the next step of the walkthrough."
  type        = list(string)
  default     = ["legacy-nginx", "legacy-python"]
}
