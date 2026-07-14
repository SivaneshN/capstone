# This module is instantiated twice from root main.tf (once for the fetcher,
# once for the query function) — the filename matches the proposal's planned
# structure, but both apod_fetcher.tf and apod_query.tf just define the same
# reusable module. Terraform merges all .tf files in a directory, so this
# works as a single module with two call sites.

variable "project_name" {
  type = string
}

variable "function_role" {
  description = "Short suffix identifying this function, e.g. 'fetcher' or 'query'"
  type        = string
}

variable "source_dir" {
  description = "Path to the Lambda source directory to zip"
  type        = string
}

variable "handler" {
  type = string
}

variable "runtime" {
  type    = string
  default = "python3.12"
}

variable "timeout" {
  type    = number
  default = 15
}

variable "memory_size" {
  type    = number
  default = 128
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "extra_policy_statements" {
  description = "Additional IAM policy statements this function needs, beyond basic CloudWatch Logs"
  type = list(object({
    sid       = string
    actions   = list(string)
    resources = list(string)
  }))
  default = []
}

variable "existing_role_arn" {
  description = <<-EOT
    Optional. If set, the Lambda function uses this existing IAM role ARN
    instead of creating a new one. Set this to your Learner Lab's LabRole ARN
    (e.g. "arn:aws:iam::123456789012:role/LabRole") if your account blocks
    iam:CreateRole / iam:CreatePolicy — which most AWS Academy / Learner Lab
    accounts do. Leave as null to create a least-privilege role per function
    (works in a normal AWS account).
  EOT
  type        = string
  default     = null
}

data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/${var.project_name}-${var.function_role}.zip"
}

locals {
  use_existing_role = var.existing_role_arn != null
}

resource "aws_iam_role" "this" {
  count = local.use_existing_role ? 0 : 1
  name  = "${var.project_name}-${var.function_role}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "basic_logging" {
  count = local.use_existing_role ? 0 : 1
  name  = "${var.project_name}-${var.function_role}-logging"
  role  = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "Logs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:*:*:*"
    }]
  })
}

resource "aws_iam_role_policy" "extra" {
  count = (!local.use_existing_role && length(var.extra_policy_statements) > 0) ? 1 : 0
  name  = "${var.project_name}-${var.function_role}-extra"
  role  = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for s in var.extra_policy_statements : {
        Sid      = s.sid
        Effect   = "Allow"
        Action   = s.actions
        Resource = s.resources
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.project_name}-${var.function_role}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.project_name}-${var.function_role}"
  role             = local.use_existing_role ? var.existing_role_arn : aws_iam_role.this[0].arn
  handler          = var.handler
  runtime          = var.runtime
  timeout          = var.timeout
  memory_size      = var.memory_size
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  environment {
    variables = var.environment_variables
  }

  depends_on = [
    aws_cloudwatch_log_group.this
  ]
}

output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "invoke_arn" {
  value = aws_lambda_function.this.invoke_arn
}

output "role_arn" {
  value = local.use_existing_role ? var.existing_role_arn : aws_iam_role.this[0].arn
}
