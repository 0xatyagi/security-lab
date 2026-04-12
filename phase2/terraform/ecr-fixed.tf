# ecr-fixed.tf
# Hardened ECR configuration — all supply chain gaps resolved

resource "aws_kms_key" "ecr" {
  description             = "KMS key for ECR image encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_ecr_repository" "webapp" {
  name = "webapp"

  # FIX: Lab 13 — immutable tags prevent silent overwrites
  image_tag_mutability = "IMMUTABLE"

  # FIX: Lab 16 — scan every image on push
  image_scanning_configuration {
    scan_on_push = true
  }

  # FIX: Lab 16 — KMS encryption for images at rest
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

# FIX: Lab 12 — no public policy
# Access controlled through IAM policies on the pulling identity only
# Private by default — no repository policy needed

# FIX: Lab 16 — lifecycle policy keeps registry clean
resource "aws_ecr_lifecycle_policy" "webapp" {
  repository = aws_ecr_repository.webapp.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only last 20 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["v*"]
          countType      = "imageCountMoreThan"
          countNumber    = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# FIX: Lab 15 — VPC endpoint so images never traverse the internet
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.us-east-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.ecr_endpoint.id]
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.us-east-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.ecr_endpoint.id]
}