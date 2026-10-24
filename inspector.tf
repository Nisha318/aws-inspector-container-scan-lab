# Step 1 of the lab: turn Inspector on for ECR container images.
# Destroying this resource disables Inspector scanning for ECR again.
resource "aws_inspector2_enabler" "this" {
  account_ids    = [local.account_id]
  resource_types = ["ECR"]
}

# Enhanced scanning hands ECR image scans over to Inspector.
# CONTINUOUS_SCAN rescans images as new CVEs are published, not only on push.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }

  depends_on = [aws_inspector2_enabler.this]
}
