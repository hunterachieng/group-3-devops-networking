locals {
  tags = merge(var.common_tags, {
    ManagedBy = "terraform"
    Module    = "ecs-platform"
  })
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ecs_exec_task_permissions" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel"
    ]
    resources = ["*"]
  }
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-cluster"
  })
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.namespace_name
  description = "Private namespace for ECS Service Connect"
  vpc         = var.vpc_id

  tags = merge(local.tags, {
    Name = var.namespace_name
  })
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-exec-role"
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-task-role"
  })
}

resource "aws_iam_role_policy" "ecs_exec_task_permissions" {
  name   = "${var.name_prefix}-ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ecs_exec_task_permissions.json
}

resource "aws_ecr_repository" "service" {
  for_each = var.service_keys

  name                 = "${var.name_prefix}-${each.key}"
  force_delete         = true
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-${each.key}"
    Service = each.key
  })
}

resource "aws_cloudwatch_log_group" "service" {
  for_each = var.service_keys

  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = merge(local.tags, {
    Name    = "/ecs/${var.name_prefix}/${each.key}"
    Service = each.key
  })
}
