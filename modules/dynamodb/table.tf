variable "project_name" {
  type = string
}

# NOTE ON THE "tags" ATTRIBUTE AND SEARCH:
# DynamoDB Global Secondary Index keys must be scalar (String/Number/Binary).
# `tags` is a List, so it cannot itself be a GSI partition key. This is
# solved with a sparse "tag index" table below: one item per (tag, date)
# pair, with `tag` as partition key. apod-fetcher writes one entry per tag
# on every run; apod-query does a Query against this table (O(1) partition
# lookup) instead of scanning the whole archive, then fetches the matching
# full records from the main table by date.

resource "aws_dynamodb_table" "apod_archive" {
  name         = "${var.project_name}-records"
  billing_mode = "PAY_PER_REQUEST" # on-demand, matches the budget estimate
  hash_key     = "date"

  attribute {
    name = "date"
    type = "S"
  }

  point_in_time_recovery {
    enabled = false # keep cost at $0 for a capstone/lab account
  }

  tags = {
    Name = "${var.project_name}-records"
  }
}

# Sparse index table for O(1) tag lookups instead of a Scan. Written to by
# apod-fetcher (one item per tag per date) and queried by apod-query.
resource "aws_dynamodb_table" "tag_index" {
  name         = "${var.project_name}-tag-index"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tag"
  range_key    = "date"

  attribute {
    name = "tag"
    type = "S"
  }

  attribute {
    name = "date"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-tag-index"
  }
}

output "table_name" {
  value = aws_dynamodb_table.apod_archive.name
}

output "table_arn" {
  value = aws_dynamodb_table.apod_archive.arn
}

output "tag_index_table_name" {
  value = aws_dynamodb_table.tag_index.name
}

output "tag_index_table_arn" {
  value = aws_dynamodb_table.tag_index.arn
}
