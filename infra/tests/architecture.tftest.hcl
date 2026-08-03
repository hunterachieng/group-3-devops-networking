# Terraform architecture tests will go here.
# Required tests/checks should detect at least six invalid designs, such as:
# - task receives a public IP
# - ALB spans fewer than two AZs
# - target group type is not ip
# - app port open to 0.0.0.0/0
# - missing required tags
# - wrong AWS region
# - image tag is latest
# - Service A can reach Service C directly

