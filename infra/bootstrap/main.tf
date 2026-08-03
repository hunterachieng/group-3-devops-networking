locals {
  state_bucket_name = "devops-g3-tfstate-827478161993-uswest1"

  common_tags = {
    project     = "devops-g3"
    group       = "group-3"
    owner       = "minage"
    environment = "lab"
  }
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
