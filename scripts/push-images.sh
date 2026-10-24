#!/usr/bin/env bash
# Pulls intentionally outdated public images and pushes them into the ECR
# repositories that Terraform created. Inspector then scans them on arrival.
#
# Requirements: AWS CLI v2 with credentials for the lab account, and a running
# Docker daemon. Terraform is not needed to run this script.
#
# Optional overrides (environment variables):
#   AWS_REGION    Region you deployed to. Default: us-east-1
#   PROJECT_NAME  Must match var.project_name in Terraform. Default: inspector-lab

set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-inspector-lab}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Format: "<ECR repository suffix>|<public source image>"
# The suffix must match an entry in var.image_repositories.
#
# Choose images built on an operating system that Inspector fully supports for
# ECR scanning (for example Debian 11 and later). Images on discontinued
# operating systems only produce limited, informational findings, which makes
# for a weak demo. Pick older patch versions so that known CVEs are present.
IMAGES=(
  "legacy-nginx|nginx:1.21.6"
  "legacy-python|python:3.9.7-slim-bullseye"
)

for tool in aws docker; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is not installed or not on your PATH." >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "Error: the Docker daemon is not running." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo "Target registry: ${REGISTRY}"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

for entry in "${IMAGES[@]}"; do
  suffix="${entry%%|*}"
  source_image="${entry#*|}"
  tag="${source_image##*:}"
  target="${REGISTRY}/${PROJECT_NAME}/${suffix}:${tag}"

  echo "==> ${source_image} -> ${target}"
  docker pull --platform linux/amd64 "$source_image"
  docker tag "$source_image" "$target"
  docker push "$target"
done

echo
echo "Push complete. Inspector starts scanning each image as it lands."
echo "Open the ECR console, select a repository, and check the image's"
echo "vulnerability counts. The first scan usually finishes within a few minutes."
