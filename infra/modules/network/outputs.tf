output "vpc_id" {
  description = "Created VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Created VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs for the ALB."
  value       = values(aws_subnet.public)[*].id
}

output "private_app_subnet_ids" {
  description = "Private subnet IDs for ECS application tasks."
  value       = values(aws_subnet.private_app)[*].id
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = aws_route_table.public.id
}

output "private_app_route_table_ids" {
  description = "Private app route table IDs."
  value       = values(aws_route_table.private_app)[*].id
}

output "internet_gateway_id" {
  description = "Internet gateway ID for public ALB ingress."
  value       = aws_internet_gateway.this.id
}

output "interface_endpoint_ids" {
  description = "Interface VPC endpoint IDs keyed by service short name."
  value       = { for name, endpoint in aws_vpc_endpoint.interface : name => endpoint.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint ID."
  value       = aws_vpc_endpoint.s3.id
}

output "endpoint_security_group_id" {
  description = "Security group used by interface endpoints."
  value       = aws_security_group.interface_endpoints.id
}
