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

variable "image_repositories" {
  description = "ECR repositories to create. You push intentionally outdated images into these in the next step of the walkthrough."
  type        = list(string)
  default     = ["legacy-nginx", "legacy-python"]
}
