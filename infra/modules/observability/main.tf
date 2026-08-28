locals {
  tags = merge(var.common_tags, {
    ManagedBy = "terraform"
    Module    = "observability"
  })

  chatbot_enabled = var.slack_team_id != "" && var.slack_channel_id != "" && var.slack_webhook_url == ""

  slack_lambda_enabled = var.slack_webhook_url != ""

  alb_dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.order_target_group_arn_suffix
  }

  alarm_prefix = "${var.name_prefix}-pr"
}

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-production-readiness-alerts"

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-production-readiness-alerts"
  })
}

resource "aws_sns_topic_subscription" "alert_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_log_metric_filter" "checkout_success" {
  name           = "${var.name_prefix}-checkout-success"
  log_group_name = var.order_log_group_name
  pattern        = "{ $.event = \"checkout_completed\" }"

  metric_transformation {
    name          = "CheckoutSuccess"
    namespace     = "${var.name_prefix}/Checkout"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "checkout_failure" {
  name           = "${var.name_prefix}-checkout-failure"
  log_group_name = var.order_log_group_name
  pattern        = "{ $.event = \"downstream_error\" }"

  metric_transformation {
    name          = "CheckoutFailure"
    namespace     = "${var.name_prefix}/Checkout"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "checkout_availability_degraded" {
  alarm_name          = "${local.alarm_prefix}-checkout-availability-degraded"
  alarm_description   = <<-EOT
    WHAT: Order target group is returning HTTP 5xx responses through the ALB.
    WHY: Customers cannot complete checkout — this directly burns the checkout availability SLO.
    WHERE: (1) ALB target health for ${var.order_target_group_arn_suffix}, (2) order ECS service events, (3) order logs for downstream_error events, (4) inventory/payment task health.
    RUNBOOK: ${var.runbook_url}
  EOT
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "target_5xx"
    return_data = true

    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"

      dimensions = local.alb_dimensions
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, {
    Name     = "${local.alarm_prefix}-checkout-availability-degraded"
    Category = "availability"
    Service  = "order"
  })
}

resource "aws_cloudwatch_metric_alarm" "checkout_latency_high" {
  alarm_name          = "${local.alarm_prefix}-checkout-latency-high"
  alarm_description   = <<-EOT
    WHAT: p95 ALB target response time for the order service exceeds ${var.checkout_latency_p95_threshold_seconds}s.
    WHY: Checkout latency SLO is at risk — customers experience slow or timing-out purchases.
    WHERE: (1) CloudWatch dashboard ${var.name_prefix}-production-readiness, (2) order Container Insights CPU/memory, (3) order/inventory/payment logs filtered by request_id, (4) recent deployments via ECS service events.
    RUNBOOK: ${var.runbook_url}
  EOT
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  threshold           = var.checkout_latency_p95_threshold_seconds
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "latency_p95"
    return_data = true

    metric {
      metric_name = "TargetResponseTime"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "p95"

      dimensions = local.alb_dimensions
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, {
    Name     = "${local.alarm_prefix}-checkout-latency-high"
    Category = "latency"
    Service  = "order"
  })
}

resource "aws_cloudwatch_metric_alarm" "order_saturation_high" {
  alarm_name          = "${local.alarm_prefix}-order-saturation-high"
  alarm_description   = <<-EOT
    WHAT: Order service CPU utilization is above ${var.order_cpu_threshold_percent}% for a sustained period.
    WHY: Saturation precedes timeouts and failed checkouts — the order service may soon stop keeping up with demand.
    WHERE: (1) ECS service ${var.order_service_name} task count and deployment status, (2) Container Insights memory for the same service, (3) ALB request rate, (4) consider scaling task count or CPU/memory in Terraform.
    RUNBOOK: ${var.runbook_url}
  EOT
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 10
  threshold           = var.order_cpu_threshold_percent
  treat_missing_data  = "notBreaching"

  metric_name = "CpuUtilized"
  namespace   = "ECS/ContainerInsights"
  period      = 60
  statistic   = "Average"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.order_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, {
    Name     = "${local.alarm_prefix}-order-saturation-high"
    Category = "saturation"
    Service  = "order"
  })
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_order_targets" {
  alarm_name          = "${local.alarm_prefix}-unhealthy-order-targets"
  alarm_description   = <<-EOT
    WHAT: One or more order tasks are failing the ALB health check.
    WHY: Reduced capacity or total loss of checkout service at the load balancer — customers may see 502/503 even if containers appear running.
    WHERE: (1) Target group health in EC2/ELB console, (2) order ECS tasks and recent deployments, (3) security group rules alb-sg → order-sg:3001, (4) order /health vs /ready responses via ECS Exec.
    RUNBOOK: ${var.runbook_url}
  EOT
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_name = "UnHealthyHostCount"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Maximum"

  dimensions = local.alb_dimensions

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, {
    Name     = "${local.alarm_prefix}-unhealthy-order-targets"
    Category = "availability"
    Service  = "order"
  })
}

resource "aws_cloudwatch_dashboard" "production_readiness" {
  dashboard_name = "${var.name_prefix}-production-readiness"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Production Readiness — Customer Checkout\nCritical journey: `POST /checkout` via ALB → Order → Inventory → Payment → confirm callback.\nSLO definitions: see `production-readiness/01-reliability-target/reliability-target.md`."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "ALB request volume (order target group)"
          view   = "timeSeries"
          region = "us-west-1"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.load_balancer_arn_suffix, "TargetGroup", var.order_target_group_arn_suffix, { label = "Requests" }],
            [".", "HTTPCode_Target_2XX_Count", ".", ".", ".", ".", { label = "2xx", color = "#2ca02c" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", ".", ".", { label = "5xx", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Checkout latency (ALB p95 target response time)"
          view   = "timeSeries"
          region = "us-west-1"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.load_balancer_arn_suffix, "TargetGroup", var.order_target_group_arn_suffix, { stat = "p95", label = "p95 latency (s)" }],
          ]
          annotations = {
            horizontal = [
              {
                label = "SLO threshold (500ms)"
                value = var.checkout_latency_p95_threshold_seconds
              }
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "Target health"
          view   = "timeSeries"
          region = "us-west-1"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.load_balancer_arn_suffix, "TargetGroup", var.order_target_group_arn_suffix, { label = "Healthy" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { label = "Unhealthy", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "Order service saturation (Container Insights)"
          view   = "timeSeries"
          region = "us-west-1"
          stat   = "Average"
          period = 60
          metrics = [
            ["ECS/ContainerInsights", "CpuUtilized", "ClusterName", var.cluster_name, "ServiceName", var.order_service_name, { label = "CPU %" }],
            [".", "MemoryUtilized", ".", ".", ".", ".", { label = "Memory %" }],
          ]
          annotations = {
            horizontal = [
              {
                label = "CPU alert threshold"
                value = var.order_cpu_threshold_percent
              }
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "Checkout outcomes (log-derived SLI)"
          view   = "timeSeries"
          region = "us-west-1"
          stat   = "Sum"
          period = 60
          metrics = [
            ["${var.name_prefix}/Checkout", "CheckoutSuccess", { label = "Success (checkout_completed)" }],
            [".", "CheckoutFailure", { label = "Failure (downstream_error on /checkout)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 24
        height = 6
        properties = {
          title  = "Checkout availability SLI (% successful checkouts from logs)"
          view   = "timeSeries"
          region = "us-west-1"
          period = 300
          metrics = [
            [{
              expression = "IF(m1+m2 > 0, 100 * m1 / (m1+m2), 100)"
              label      = "Availability %"
              id         = "availability"
            }],
            ["${var.name_prefix}/Checkout", "CheckoutSuccess", { id = "m1", visible = false }],
            [".", "CheckoutFailure", { id = "m2", visible = false }],
          ]
          yAxis = {
            left = {
              min = 0
              max = 100
            }
          }
        }
      }
    ]
  })
}
