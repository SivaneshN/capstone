output "api_base_url" {
  description = "Base URL for the API Gateway HTTP API. Append /today or /search?tag=X"
  value       = module.api_gateway.api_endpoint
}

output "today_endpoint" {
  description = "Full URL for today's enriched record"
  value       = "${module.api_gateway.api_endpoint}/today"
}

output "search_endpoint_example" {
  description = "Example full URL for a tag search"
  value       = "${module.api_gateway.api_endpoint}/search?tag=galaxy"
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "s3_bucket_name" {
  value = module.s3.bucket_name
}

output "secrets_manager_secret_name" {
  value = module.secrets_manager.secret_name
}

output "cloudwatch_dashboard_url" {
  description = "Console URL for the CloudWatch dashboard"
  value       = module.cloudwatch.dashboard_url
}

output "lambda_fetcher_name" {
  value = module.lambda_fetcher.function_name
}

output "lambda_query_name" {
  value = module.lambda_query.function_name
}
