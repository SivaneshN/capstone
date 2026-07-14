variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix for all resources"
  type        = string
  default     = "apod-archive"
}

variable "environment" {
  description = "Deployment environment tag"
  type        = string
  default     = "capstone"
}

variable "nasa_api_key" {
  description = "NASA APOD API key (get one free at https://api.nasa.gov). Passed in via terraform.tfvars or TF_VAR_nasa_api_key env var — never commit this value."
  type        = string
  sensitive   = true
}

variable "schedule_cron" {
  description = "EventBridge cron expression for the daily fetch. Default: 08:00 UTC every day."
  type        = string
  default     = "cron(0 8 * * ? *)"
}

variable "tag_confidence_threshold" {
  description = "Minimum Comprehend confidence score (0-1) required to keep a key phrase / entity as a tag"
  type        = number
  default     = 0.85
}

variable "max_tags" {
  description = "Maximum number of tags stored per record"
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days"
  type        = number
  default     = 14
}

variable "lab_role_arn" {
  description = <<-EOT
    Optional. Set this to your AWS Academy / Learner Lab "LabRole" ARN
    (find it via `aws iam get-role --role-name LabRole --query Role.Arn`)
    if your account blocks creating new IAM roles/policies. When set, both
    Lambda functions use this role instead of Terraform-created ones. Leave
    as null/empty in a normal AWS account so Terraform creates least-
    privilege roles per function.
  EOT
  type        = string
  default     = null
}
