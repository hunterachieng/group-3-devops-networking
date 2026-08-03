// Network module resources will go here.
// This module will create:
// - custom VPC
// - public subnets for the ALB
// - private app subnets for ECS Fargate tasks
// - route tables
// - Internet Gateway for public subnets
// - VPC endpoints for private ECS task egress:
//   ecr.api, ecr.dkr, logs, sts, and S3 gateway
// This design avoids NAT Gateway unless third-party outbound internet is required.

