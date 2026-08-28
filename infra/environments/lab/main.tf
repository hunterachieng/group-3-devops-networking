module "network" {
  source = "../../modules/network"

  name_prefix = var.name_prefix
  common_tags = var.common_tags
}

module "alb" {
  source = "../../modules/alb"

  name_prefix       = var.name_prefix
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  common_tags       = var.common_tags
}

module "ecs_platform" {
  source = "../../modules/ecs-platform"

  name_prefix = var.name_prefix
  vpc_id      = module.network.vpc_id
  common_tags = var.common_tags
}

module "order" {
  source = "../../modules/ecs-service"

  name_prefix                    = var.name_prefix
  service_key                    = "order"
  container_name                 = "order"
  container_port                 = 3001
  port_name                      = "order-3001"
  desired_count                  = 2
  repository_url                 = module.ecs_platform.repository_urls["order"]
  image_tag                      = var.order_image_tag
  cluster_arn                    = module.ecs_platform.cluster_arn
  vpc_id                         = module.network.vpc_id
  private_subnet_ids             = module.network.private_app_subnet_ids
  task_execution_role_arn        = module.ecs_platform.task_execution_role_arn
  task_role_arn                  = module.ecs_platform.task_role_arn
  log_group_name                 = module.ecs_platform.log_group_names["order"]
  log_region                     = var.region
  service_connect_namespace_arn  = module.ecs_platform.service_connect_namespace_arn
  service_connect_discovery_name = "order"
  alb_target_group_arn           = module.alb.order_target_group_arn
  common_tags                    = var.common_tags

  ingress_rules = {
    from-alb = {
      description              = "ALB to order"
      from_port                = 3001
      to_port                  = 3001
      protocol                 = "tcp"
      source_security_group_id = module.alb.alb_security_group_id
    }
  }
}

module "inventory" {
  source = "../../modules/ecs-service"

  name_prefix                    = var.name_prefix
  service_key                    = "inventory"
  container_name                 = "inventory"
  container_port                 = 3002
  port_name                      = "inventory-3002"
  desired_count                  = 1
  repository_url                 = module.ecs_platform.repository_urls["inventory"]
  image_tag                      = var.inventory_image_tag
  cluster_arn                    = module.ecs_platform.cluster_arn
  vpc_id                         = module.network.vpc_id
  private_subnet_ids             = module.network.private_app_subnet_ids
  task_execution_role_arn        = module.ecs_platform.task_execution_role_arn
  task_role_arn                  = module.ecs_platform.task_role_arn
  log_group_name                 = module.ecs_platform.log_group_names["inventory"]
  log_region                     = var.region
  service_connect_namespace_arn  = module.ecs_platform.service_connect_namespace_arn
  service_connect_discovery_name = "inventory"
  common_tags                    = var.common_tags

  ingress_rules = {
    from-order = {
      description              = "Order to inventory"
      from_port                = 3002
      to_port                  = 3002
      protocol                 = "tcp"
      source_security_group_id = module.order.security_group_id
    }
  }

  depends_on = [module.order]
}

module "payment" {
  source = "../../modules/ecs-service"

  name_prefix                    = var.name_prefix
  service_key                    = "payment"
  container_name                 = "payment"
  container_port                 = 3003
  port_name                      = "payment-3003"
  desired_count                  = 1
  repository_url                 = module.ecs_platform.repository_urls["payment"]
  image_tag                      = var.payment_image_tag
  cluster_arn                    = module.ecs_platform.cluster_arn
  vpc_id                         = module.network.vpc_id
  private_subnet_ids             = module.network.private_app_subnet_ids
  task_execution_role_arn        = module.ecs_platform.task_execution_role_arn
  task_role_arn                  = module.ecs_platform.task_role_arn
  log_group_name                 = module.ecs_platform.log_group_names["payment"]
  log_region                     = var.region
  service_connect_namespace_arn  = module.ecs_platform.service_connect_namespace_arn
  service_connect_discovery_name = "payment"
  common_tags                    = var.common_tags

  ingress_rules = {
    from-inventory = {
      description              = "Inventory to payment"
      from_port                = 3003
      to_port                  = 3003
      protocol                 = "tcp"
      source_security_group_id = module.inventory.security_group_id
    }
  }

  depends_on = [module.inventory]
}

# Payment → Order /confirm callback. Root-level only to avoid module dependency cycle.
resource "aws_vpc_security_group_ingress_rule" "payment_to_order_confirm" {
  security_group_id            = module.order.security_group_id
  referenced_security_group_id = module.payment.security_group_id
  from_port                    = 3001
  to_port                      = 3001
  ip_protocol                  = "tcp"
  description                  = "Payment confirm callback to order"

  depends_on = [module.order, module.payment]
}

module "observability" {
  source = "../../modules/observability"

  name_prefix                   = var.name_prefix
  common_tags                   = var.common_tags
  cluster_name                  = module.ecs_platform.cluster_name
  order_service_name            = module.order.service_name
  load_balancer_arn_suffix      = module.alb.load_balancer_arn_suffix
  order_target_group_arn_suffix = module.alb.order_target_group_arn_suffix
  order_log_group_name          = module.ecs_platform.log_group_names["order"]
  alert_email                   = var.alert_email
  slack_team_id                 = var.slack_team_id
  slack_channel_id              = var.slack_channel_id
  slack_webhook_url             = var.slack_webhook_url
  slack_channel_name            = var.slack_channel_name

  depends_on = [module.order]
}
