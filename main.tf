terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# Persistent state: DynamoDB table + S3 bucket
# ---------------------------------------------------------------------------
module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
}

module "s3" {
  source       = "./modules/s3"
  project_name = var.project_name
}

# ---------------------------------------------------------------------------
# Secret management: NASA API key
# ---------------------------------------------------------------------------
module "secrets_manager" {
  source       = "./modules/secrets_manager"
  project_name = var.project_name
  nasa_api_key = var.nasa_api_key
}

# ---------------------------------------------------------------------------
# Compute: apod-fetcher and apod-query Lambda functions
# ---------------------------------------------------------------------------
module "lambda_fetcher" {
  source = "./modules/lambda"

  project_name       = var.project_name
  function_role      = "fetcher"
  source_dir         = "${path.module}/src/apod_fetcher"
  handler            = "handler.lambda_handler"
  timeout            = 30
  memory_size        = 256
  log_retention_days = var.log_retention_days

  environment_variables = {
    TABLE_NAME               = module.dynamodb.table_name
    TAG_INDEX_TABLE_NAME     = module.dynamodb.tag_index_table_name
    BUCKET_NAME              = module.s3.bucket_name
    SECRET_ARN               = module.secrets_manager.secret_arn
    TAG_CONFIDENCE_THRESHOLD = tostring(var.tag_confidence_threshold)
    MAX_TAGS                 = tostring(var.max_tags)
  }

  existing_role_arn = var.lab_role_arn

  extra_policy_statements = [
    {
      sid       = "DynamoDBWrite"
      actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
      resources = [module.dynamodb.table_arn, module.dynamodb.tag_index_table_arn]
    },
    {
      sid       = "S3Write"
      actions   = ["s3:PutObject"]
      resources = ["${module.s3.bucket_arn}/*"]
    },
    {
      sid       = "SecretsRead"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [module.secrets_manager.secret_arn]
    },
    {
      sid       = "ComprehendAnalyze"
      actions   = ["comprehend:DetectKeyPhrases", "comprehend:DetectEntities"]
      resources = ["*"]
    }
  ]
}

module "lambda_query" {
  source = "./modules/lambda"

  project_name       = var.project_name
  function_role      = "query"
  source_dir         = "${path.module}/src/apod_query"
  handler            = "handler.lambda_handler"
  timeout            = 10
  memory_size        = 128
  log_retention_days = var.log_retention_days

  environment_variables = {
    TABLE_NAME           = module.dynamodb.table_name
    TAG_INDEX_TABLE_NAME = module.dynamodb.tag_index_table_name
  }

  existing_role_arn = var.lab_role_arn

  extra_policy_statements = [
    {
      sid       = "DynamoDBRead"
      actions   = ["dynamodb:GetItem", "dynamodb:Scan", "dynamodb:Query", "dynamodb:BatchGetItem"]
      resources = [module.dynamodb.table_arn, module.dynamodb.tag_index_table_arn]
    }
  ]
}

# ---------------------------------------------------------------------------
# Schedule trigger: EventBridge -> apod-fetcher
# ---------------------------------------------------------------------------
module "eventbridge" {
  source               = "./modules/eventbridge"
  project_name         = var.project_name
  schedule_cron        = var.schedule_cron
  lambda_function_arn  = module.lambda_fetcher.function_arn
  lambda_function_name = module.lambda_fetcher.function_name
}

# ---------------------------------------------------------------------------
# External integration: API Gateway -> apod-query
# ---------------------------------------------------------------------------
module "api_gateway" {
  source               = "./modules/api_gateway"
  project_name         = var.project_name
  lambda_function_arn  = module.lambda_query.function_arn
  lambda_function_name = module.lambda_query.function_name
  lambda_invoke_arn    = module.lambda_query.invoke_arn
}

# ---------------------------------------------------------------------------
# Frontend: static website (S3) that calls the apod-query API
# ---------------------------------------------------------------------------
module "website" {
  source       = "./modules/website"
  project_name = var.project_name
  site_dir     = "${path.module}/site"
  api_base_url = module.api_gateway.api_endpoint
}

# ---------------------------------------------------------------------------
# Observability: CloudWatch dashboard + alarms
# ---------------------------------------------------------------------------
module "cloudwatch" {
  source                = "./modules/cloudwatch"
  project_name          = var.project_name
  aws_region            = var.aws_region
  fetcher_function_name = module.lambda_fetcher.function_name
  query_function_name   = module.lambda_query.function_name
  dynamodb_table_name   = module.dynamodb.table_name
  alarm_email           = var.alarm_email
}
