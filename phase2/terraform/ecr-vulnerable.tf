# ecr-vulnerable.tf
# ECR configuration with all supply chain gaps present
# Covers: Lab 12 (public access), Lab 13 (mutable tags), Lab 16 (no scanning/lifecycle)

resource "aws_ecr_repository" "webapp" {
  name = "webapp"

  # GAP: Lab 13 — tags are mutable by default
  # Anyone with push access can overwrite v1.0.0 silently
  image_tag_mutability = "MUTABLE"

  # GAP: Lab 16 — scan on push disabled
  image_scanning_configuration {
    scan_on_push = false
  }

  # GAP: Lab 16 — no KMS encryption
  # Images stored with default AWS-managed encryption only
}

# GAP: Lab 12 — public repository policy
# Principal "*" means anyone on the internet can pull
resource "aws_ecr_repository_policy" "webapp_public" {
  repository = aws_ecr_repository.webapp.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowPublicPull"
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ]
    }]
  })
}

# GAP: Lab 16 — no lifecycle policy
# Old and untagged images accumulate forever
# Stale images from months ago remain deployable