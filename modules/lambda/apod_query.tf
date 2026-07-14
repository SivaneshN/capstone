# This file intentionally has no resources.
#
# The proposal's planned structure listed apod_fetcher.tf and apod_query.tf
# as separate files under modules/lambda/. In practice both Lambda functions
# (apod-fetcher and apod-query) are built from the SAME reusable module
# (defined in apod_fetcher.tf) and instantiated twice from the root main.tf:
#
#   module "lambda_fetcher" { source = "./modules/lambda" ... }
#   module "lambda_query"   { source = "./modules/lambda" ... }
#
# Terraform merges every .tf file in a module directory into one namespace,
# so defining the aws_lambda_function resource twice (once per file) would
# collide. This file is kept as a placeholder so the folder structure matches
# the proposal exactly; all logic lives in apod_fetcher.tf.
