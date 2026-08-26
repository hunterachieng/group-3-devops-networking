output "state_bucket_name" {
  description = "S3 bucket used for Terraform remote state (workload stacks)."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform remote state bucket."
  value       = aws_s3_bucket.tfstate.arn
}

output "gha_deploy_role_arn" {
  description = "IAM role GitHub Actions assumes (via OIDC) to deploy the lab workload."
  value       = aws_iam_role.gha_deploy.arn
}
