# Architecture rules as code for the lab root module.
# Run from: infra/environments/lab
#   terraform test
# or:
#   terraform test -test-directory=tests
#
# mock_provider replaces the real AWS provider so these tests run without
# credentials in CI. expect_failures tests fail at variable validation before
# any provider call; the positive plan test needs mock_data to avoid invalid
# JSON on aws_iam_policy_document.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "reject_latest_order_image_tag" {
  command = plan

  variables {
    order_image_tag = "latest"
  }

  expect_failures = [
    var.order_image_tag,
  ]
}

run "reject_latest_inventory_image_tag" {
  command = plan

  variables {
    inventory_image_tag = "latest"
  }

  expect_failures = [
    var.inventory_image_tag,
  ]
}

run "reject_latest_payment_image_tag" {
  command = plan

  variables {
    payment_image_tag = "latest"
  }

  expect_failures = [
    var.payment_image_tag,
  ]
}

run "reject_unapproved_region" {
  command = plan

  variables {
    region = "eu-west-1"
  }

  expect_failures = [
    var.region,
  ]
}

run "reject_invalid_image_sha" {
  command = plan

  variables {
    order_image_tag = "not-a-sha"
  }

  expect_failures = [
    var.order_image_tag,
  ]
}

run "reject_missing_required_tags" {
  command = plan

  variables {
    common_tags = {
      project = "devops-g3"
    }
  }

  expect_failures = [
    var.common_tags,
  ]
}

run "accept_valid_git_sha_tags" {
  command = plan

  variables {
    order_image_tag     = "09823d5"
    inventory_image_tag = "41eb453"
    payment_image_tag   = "f16e6ef"
  }
}
