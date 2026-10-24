# Step 1 of the lab: turn Inspector on for ECR container images.
# Both resources are account-wide and are skipped when var.manage_inspector is false.
# Destroying this resource disables Inspector scanning for ECR again.
resource "aws_inspector2_enabler" "this" {
  count = var.manage_inspector ? 1 : 0

  account_ids    = [local.account_id]
  resource_types = ["ECR"]
}

# Enhanced scanning hands ECR image scans over to Inspector.
# CONTINUOUS_SCAN rescans images as new CVEs are published, not only on push.
resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.manage_inspector ? 1 : 0

  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    # Scoped to the lab's repositories only. A bare "*" would switch every
    # repository in the registry to continuous Inspector scanning, which also
    # means billing for images that have nothing to do with this lab.
    repository_filter {
      filter      = "${var.project_name}/*"
      filter_type = "WILDCARD"
    }
  }

  depends_on = [aws_inspector2_enabler.this]
}

# These moved blocks keep state from before the toggle existed. Without them,
# Terraform would plan to destroy and recreate both resources, which briefly
# switches Inspector off. New readers can ignore them, and they can be deleted
# once everyone has applied.
moved {
  from = aws_inspector2_enabler.this
  to   = aws_inspector2_enabler.this[0]
}

moved {
  from = aws_ecr_registry_scanning_configuration.this
  to   = aws_ecr_registry_scanning_configuration.this[0]
}
