variable "project_name" {
  type = string
}

variable "api_base_url" {
  description = "Base URL of the apod-query API Gateway, injected into the frontend as config.js"
  type        = string
}

variable "site_dir" {
  description = "Path to the static site source directory"
  type        = string
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "site" {
  bucket        = "${var.project_name}-site-${random_id.suffix.hex}"
  force_destroy = true # allows `terraform destroy` to clean up a lab account easily

  tags = {
    Name = "${var.project_name}-site"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_policy" "public_read" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

locals {
  mime_types = {
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
  }
}

resource "aws_s3_object" "static_files" {
  for_each = setunion(
    fileset(var.site_dir, "*.html"),
    fileset(var.site_dir, "*.css"),
    fileset(var.site_dir, "*.js"),
  )

  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${var.site_dir}/${each.value}"
  etag         = filemd5("${var.site_dir}/${each.value}")
  content_type = lookup(local.mime_types, regex("\\.[^.]+$", each.value), "application/octet-stream")
}

resource "aws_s3_object" "config" {
  bucket       = aws_s3_bucket.site.id
  key          = "config.js"
  content      = templatefile("${var.site_dir}/config.js.tmpl", { api_base_url = var.api_base_url })
  etag         = md5(templatefile("${var.site_dir}/config.js.tmpl", { api_base_url = var.api_base_url }))
  content_type = "application/javascript"
}

output "website_url" {
  value = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}"
}
