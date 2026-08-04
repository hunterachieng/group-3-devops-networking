# Structural architecture rules — mock apply (no real AWS credentials needed).
# These tests verify that the IaC configuration enforces the required
# network topology contracts regardless of what values AWS would assign at
# runtime.
#
# Run together with the input-validation tests:
#   cd infra/environments/lab && terraform test -test-directory=tests

mock_provider "aws" {}

# ---------------------------------------------------------------------------
# Single apply run — all structural assertions in one block so the mock
# infrastructure is created once and re-used across checks.
# ---------------------------------------------------------------------------
run "structural_architecture_rules" {
  command = apply

  variables {
    order_image_tag     = "09823d5"
    inventory_image_tag = "41eb453"
    payment_image_tag   = "f16e6ef"
  }

  # Rule: no public IP on private Fargate tasks (inventory + payment)
  assert {
    condition     = !module.inventory.assign_public_ip
    error_message = "Inventory is a private service — assign_public_ip must be false."
  }

  assert {
    condition     = !module.payment.assign_public_ip
    error_message = "Payment is a private service — assign_public_ip must be false."
  }

  # Rule: ALB target group must use target_type = ip (required for Fargate awsvpc)
  assert {
    condition     = module.alb.order_target_group_target_type == "ip"
    error_message = "ALB target group must use target_type=ip for Fargate awsvpc networking."
  }

  # Rule: A→B path exists (inventory has exactly 1 ingress rule: from order)
  assert {
    condition     = module.inventory.ingress_rule_count == 1
    error_message = "Inventory SG must have exactly 1 ingress rule (from order-sg). A→B path missing."
  }

  # Rule: B→C path exists AND A→C is denied (payment has exactly 1 ingress rule:
  # from inventory only — order-sg is NOT in the ingress_rules map, so a direct
  # A→C connection is denied at the security-group level by design).
  assert {
    condition     = module.payment.ingress_rule_count == 1
    error_message = "Payment SG must have exactly 1 ingress rule (from inventory only). Direct A→C access must be denied — adding a second rule here breaks the isolation contract."
  }
}
