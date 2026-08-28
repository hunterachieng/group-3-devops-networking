# AWS Chatbot delivers SNS alarm notifications to Slack.
# Prerequisite: authorize your Slack workspace once in the AWS console —
# AWS Chatbot → Configure new client → Slack → allow access.
# Then set slack_team_id and slack_channel_id (see docs/BOOTSTRAP-EXPLAINED.md).

data "aws_iam_policy_document" "chatbot_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot" {
  count = local.chatbot_enabled ? 1 : 0

  name               = "${var.name_prefix}-chatbot-alerts"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume_role.json

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-chatbot-alerts"
  })
}

resource "aws_iam_role_policy_attachment" "chatbot_readonly" {
  count = local.chatbot_enabled ? 1 : 0

  role       = aws_iam_role.chatbot[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_chatbot_slack_channel_configuration" "alerts" {
  count = local.chatbot_enabled ? 1 : 0

  configuration_name = "${var.name_prefix}-slack-alerts"
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_team_id
  sns_topic_arns     = [aws_sns_topic.alerts.arn]
  logging_level      = "INFO"

  guardrail_policy_arns = [
    "arn:aws:iam::aws:policy/ReadOnlyAccess",
  ]

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-slack-alerts"
  })
}
