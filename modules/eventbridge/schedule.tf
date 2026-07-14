variable "project_name" {
  type = string
}

variable "schedule_cron" {
  type = string
}

variable "lambda_function_arn" {
  type = string
}

variable "lambda_function_name" {
  type = string
}

resource "aws_cloudwatch_event_rule" "daily_fetch" {
  name                = "${var.project_name}-daily-fetch"
  description         = "Triggers apod-fetcher once a day"
  schedule_expression = var.schedule_cron
}

resource "aws_cloudwatch_event_target" "fetcher" {
  rule      = aws_cloudwatch_event_rule.daily_fetch.name
  target_id = "apod-fetcher"
  arn       = var.lambda_function_arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_fetch.arn
}

output "rule_arn" {
  value = aws_cloudwatch_event_rule.daily_fetch.arn
}
