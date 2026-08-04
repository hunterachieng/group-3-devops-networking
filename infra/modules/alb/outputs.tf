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
