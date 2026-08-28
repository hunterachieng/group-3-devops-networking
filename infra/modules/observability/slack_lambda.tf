# SNS → Lambda → Slack Incoming Webhook (no AWS Chatbot console OAuth required).

data "archive_file" "slack_notifier" {
  count = local.slack_lambda_enabled ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/build/slack_notifier.zip"

  source {
    content  = file("${path.module}/lambda/slack_notifier.py")
    filename = "index.py"
  }
}

data "aws_iam_policy_document" "slack_notifier_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "slack_notifier" {
  count = local.slack_lambda_enabled ? 1 : 0

  name               = "${var.name_prefix}-slack-notifier"
  assume_role_policy = data.aws_iam_policy_document.slack_notifier_assume_role.json

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-slack-notifier"
  })
}

resource "aws_iam_role_policy_attachment" "slack_notifier_basic" {
  count = local.slack_lambda_enabled ? 1 : 0

  role       = aws_iam_role.slack_notifier[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "slack_notifier" {
  count = local.slack_lambda_enabled ? 1 : 0

  name              = "/aws/lambda/${var.name_prefix}-slack-notifier"
  retention_in_days = 14

  tags = merge(local.tags, {
    Name = "/aws/lambda/${var.name_prefix}-slack-notifier"
  })
}

resource "aws_lambda_function" "slack_notifier" {
  count = local.slack_lambda_enabled ? 1 : 0

  function_name = "${var.name_prefix}-slack-notifier"
  role          = aws_iam_role.slack_notifier[0].arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 15
  memory_size   = 128

  filename         = data.archive_file.slack_notifier[0].output_path
  source_code_hash = data.archive_file.slack_notifier[0].output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
      SLACK_CHANNEL     = var.slack_channel_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.slack_notifier,
    aws_iam_role_policy_attachment.slack_notifier_basic,
  ]

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-slack-notifier"
  })
}

resource "aws_lambda_permission" "slack_notifier_sns" {
  count = local.slack_lambda_enabled ? 1 : 0

  statement_id   = "AllowExecutionFromSNS"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.slack_notifier[0].function_name
  principal      = "sns.amazonaws.com"
  source_arn     = aws_sns_topic.alerts.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_sns_topic_subscription" "slack_lambda" {
  count = local.slack_lambda_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier[0].arn

  depends_on = [aws_lambda_permission.slack_notifier_sns]
}

data "aws_caller_identity" "current" {}
