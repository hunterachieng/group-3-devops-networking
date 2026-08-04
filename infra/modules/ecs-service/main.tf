locals {
  service_name = "${var.name_prefix}-${var.service_key}"
  image        = "${var.repository_url}:${var.image_tag}"

  base_environment = {
    BIND_HOST         = "0.0.0.0"
    GIT_SHA           = var.image_tag
    OTEL_SDK_DISABLED = "true"
    PYTHONUNBUFFERED  = "1"
    SERVICE_PORT      = tostring(var.container_port)
  }

  environment = [
    for name, value in merge(local.base_environment, var.environment_variables) : {
      name  = name
      value = value
    }
  ]

  tags = merge(var.common_tags, {
    ManagedBy = "terraform"
    Module    = "ecs-service"
    Service   = var.service_key
  })
}

resource "aws_security_group" "service" {
  name        = "${local.service_name}-sg"
  description = "Ingress rules for ${local.service_name}"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, {
    Name = "${local.service_name}-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "service" {
  for_each = var.ingress_rules

  security_group_id            = aws_security_group.service.id
  referenced_security_group_id = each.value.source_security_group_id
  from_port                    = each.value.from_port
  ip_protocol                  = each.value.protocol
  to_port                      = each.value.to_port
  description                  = each.value.description
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Service egress to VPC endpoints and allowed downstream services"
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.service_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = local.image
      essential = true

      portMappings = [
        {
          name          = var.port_name
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = local.environment

      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS http://localhost:${var.container_port}/health || exit 1"]
        interval    = 30
        retries     = 3
        startPeriod = 20
        timeout     = 5
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.log_group_name
          awslogs-region        = var.log_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = merge(local.tags, {
    Name = local.service_name
  })
}

resource "aws_ecs_service" "this" {
  name                              = local.service_name
  cluster                           = var.cluster_arn
  task_definition                   = aws_ecs_task_definition.this.arn
  desired_count                     = var.desired_count
  enable_execute_command            = true
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = var.alb_target_group_arn == null ? null : 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    assign_public_ip = var.assign_public_ip
    security_groups  = [aws_security_group.service.id]
    subnets          = var.private_subnet_ids
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.service_connect_namespace_arn

    service {
      port_name      = var.port_name
      discovery_name = var.service_connect_discovery_name

      client_alias {
        dns_name = var.service_connect_discovery_name
        port     = var.container_port
      }
    }
  }

  dynamic "load_balancer" {
    for_each = var.alb_target_group_arn == null ? [] : [var.alb_target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = var.container_name
      container_port   = var.container_port
    }
  }

  tags = merge(local.tags, {
    Name = local.service_name
  })
}
