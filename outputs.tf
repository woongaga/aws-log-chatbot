output "website_endpoint" {
  value = aws_s3_bucket_website_configuration.page_bucket.website_endpoint
}

output "lambda_function_url" {
  value = aws_lambda_function_url.api.function_url
}

output "alb_dns_name" {
  value = module.alb_asg.alb_dns_name
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "log_bucket" {
  value = aws_s3_bucket.log.id
}
