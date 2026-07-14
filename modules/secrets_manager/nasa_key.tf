variable "project_name" {
  type = string
}

variable "nasa_api_key" {
  type      = string
  sensitive = true
}

resource "aws_secretsmanager_secret" "nasa_api_key" {
  name        = "${var.project_name}/nasa-api-key"
  description = "NASA APOD API key, injected into apod-fetcher Lambda at cold start"
}

resource "aws_secretsmanager_secret_version" "nasa_api_key" {
  secret_id     = aws_secretsmanager_secret.nasa_api_key.id
  secret_string = jsonencode({
    api_key = var.nasa_api_key
  })
}

output "secret_arn" {
  value = aws_secretsmanager_secret.nasa_api_key.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.nasa_api_key.name
}
