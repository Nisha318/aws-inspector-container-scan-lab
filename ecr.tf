resource "aws_ecr_repository" "lab" {
  for_each = toset(var.image_repositories)

  name                 = "${var.project_name}/${each.value}"
  image_tag_mutability = "MUTABLE"

  # Images are pushed outside Terraform, so force_delete lets
  # terraform destroy remove the repos even when they contain images.
  force_delete = true

  encryption_configuration {
    encryption_type = "AES256"
  }

  depends_on = [aws_ecr_registry_scanning_configuration.this]
}
