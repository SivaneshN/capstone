variable "project_name" {
  type = string
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "archive" {
  bucket        = "${var.project_name}-archive-${random_id.suffix.hex}"
  force_destroy = true # allows `terraform destroy` to clean up a lab account easily

  tags = {
    Name = "${var.project_name}-archive"
  }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "bucket_name" {
  value = aws_s3_bucket.archive.id
}

output "bucket_arn" {
  value = aws_s3_bucket.archive.arn
}
