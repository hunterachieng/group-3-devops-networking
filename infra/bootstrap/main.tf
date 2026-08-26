locals {
  state_bucket_name = "devops-g3-tfstate-240462142849-uswest1"

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

# GitHub Actions OIDC federation. The provider itself is account-level, shared
# infrastructure provisioned outside this repo — looked up by data source rather
# than owned/managed here, so a `terraform destroy` of this stack can never
# remove the OIDC trust for other consumers of the account.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "gha_deploy_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:hunterachieng/group-3-devops-networking:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "devops-g3-gha-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_assume_role.json

  tags = merge(local.common_tags, {
    Name = "devops-g3-gha-deploy-role"
  })
}

data "aws_iam_policy_document" "gha_deploy_permissions" {
  statement {
    sid       = "StateBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
  }

  statement {
    sid       = "ImageTagLookup"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:us-west-1:*:parameter/devops-g3-iac/*/image-tag"]
  }

  statement {
    sid = "NetworkAlbEcsEcr"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "ecs:*",
      "ecr:*",
      "servicediscovery:*",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "LogGroups"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:us-west-1:*:log-group:/ecs/devops-g3-iac*"]
  }

  statement {
    sid = "ScopedIamForEcsPlatformRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::*:role/devops-g3-iac-*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy_permissions" {
  name   = "terraform-deploy-permissions"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy_permissions.json
}
