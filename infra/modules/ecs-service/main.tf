// Reusable ECS service resources will go here.
// This module will create one service at a time:
// - ECR repository if owned by Terraform
// - CloudWatch log group
// - security group
// - ECS task definition
// - ECS service
// - Service Connect configuration
// - deployment circuit breaker with rollback
// - ECS Exec configuration
// Fargate tasks must use awsvpc mode and no public IPs.

