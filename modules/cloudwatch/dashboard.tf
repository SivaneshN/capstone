variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "fetcher_function_name" {
  type = string
}

variable "query_function_name" {
  type = string
}

variable "dynamodb_table_name" {
  type = string
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "apod-fetcher: Invocations / Errors"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.fetcher_function_name, { stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.fetcher_function_name, { stat = "Sum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "apod-fetcher: Duration (Comprehend + NASA API + writes)"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.fetcher_function_name, { stat = "Average" }],
            ["AWS/Lambda", "Duration", "FunctionName", var.fetcher_function_name, { stat = "Maximum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "apod-query: Invocations / Errors"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.query_function_name, { stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.query_function_name, { stat = "Sum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB write errors / throttles"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/DynamoDB", "SystemErrors", "TableName", var.dynamodb_table_name, { stat = "Sum" }],
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", var.dynamodb_table_name, { stat = "Sum" }],
            ["AWS/DynamoDB", "UserErrors", "TableName", var.dynamodb_table_name, { stat = "Sum" }]
          ]
        }
      }
    ]
  })
}

# Alarm: fires if the daily fetch errors out (fetch success rate observability)
resource "aws_cloudwatch_metric_alarm" "fetcher_errors" {
  alarm_name          = "${var.project_name}-fetcher-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 86400 # one day, matches the daily schedule
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "apod-fetcher failed on its daily run"
  treat_missing_data   = "notBreaching"

  dimensions = {
    FunctionName = var.fetcher_function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_write_errors" {
  alarm_name          = "${var.project_name}-dynamodb-write-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "SystemErrors"
  namespace           = "AWS/DynamoDB"
  period              = 86400
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "DynamoDB returned system errors on the archive table"
  treat_missing_data   = "notBreaching"

  dimensions = {
    TableName = var.dynamodb_table_name
  }
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
