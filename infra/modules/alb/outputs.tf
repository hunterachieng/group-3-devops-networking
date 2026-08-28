output "alb_arn" {
  description = "Application Load Balancer ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "Public DNS name for the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_security_group_id" {
  description = "Security group ID attached to the ALB."
  value       = aws_security_group.alb.id
}

output "http_listener_arn" {
  description = "HTTP listener ARN."
  value       = aws_lb_listener.http.arn
}

output "order_target_group_arn" {
  description = "Target group ARN for the order service."
  value       = aws_lb_target_group.order.arn
  depends_on  = [aws_lb_listener.http]
}

output "order_target_group_target_type" {
  description = "Target group registration type (must be ip for Fargate awsvpc networking)."
  value       = aws_lb_target_group.order.target_type
}

output "load_balancer_arn_suffix" {
  description = "Load balancer dimension suffix for CloudWatch metrics (app/name/id)."
  value       = aws_lb.this.arn_suffix
}

output "order_target_group_arn_suffix" {
  description = "Order target group dimension suffix for CloudWatch metrics (targetgroup/name/id)."
  value       = aws_lb_target_group.order.arn_suffix
}
