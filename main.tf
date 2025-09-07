locals {
  common_tags = {
    Project = var.project
  }

  website_origin = "http://${var.page_bucket}.s3-website.${var.aws_region}.amazonaws.com"
}

# -------------------------
# VPC (2AZ: 공/사 서브넷 + NAT)
# -------------------------
module "vpc" {
  source   = "./modules/vpc"
  vpc_cidr = var.vpc_cidr
  az_count = var.az_count
  tags     = local.common_tags

  # Flow Logs가 쓸 S3 (프리픽스 포함 ARN)
  vpc_flow_s3_arn_with_prefix = "arn:aws:s3:::${var.log_bucket}/${var.vpc_prefix}"
}

# -------------------------
# RDS MySQL
# -------------------------
module "rds" {
  source             = "./modules/rds"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_db_subnet_ids
  db_username        = var.db_username
  db_password        = var.db_password
  db_name            = var.db_name
  tags               = local.common_tags
}

# -------------------------
# ALB + ASG(EC2 Ubuntu 22.04)
# -------------------------
module "alb_asg" {
  source             = "./modules/alb_asg"
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_app_subnet_ids
  log_bucket         = var.log_bucket

  # RDS 접속 정보(EC2 userdata에서 PHP 페이지로 간단 연결)
  db_endpoint = module.rds.endpoint
  db_name     = var.db_name
  db_username = var.db_username
  db_password = var.db_password

  tags = local.common_tags
}

# -------------------------
# S3 - 정적 웹사이트 (aichatpage)
# -------------------------
resource "aws_s3_bucket" "page" {
  bucket        = var.page_bucket
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "page" {
  bucket                  = aws_s3_bucket.page.id
  block_public_acls       = false
  block_public_policy     = false
  restrict_public_buckets = false
  ignore_public_acls      = false
}

resource "aws_s3_bucket_website_configuration" "page_bucket" {
  bucket = aws_s3_bucket.page.id
  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.page.id
  key          = "index.html"
  source       = "${path.root}/files/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.root}/files/index.html")
}

# 퍼블릭 읽기 정책 (버킷 공개차단 해제 후 적용되도록 의존성 추가)
resource "aws_s3_bucket_policy" "page" {
  bucket = aws_s3_bucket.page.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "PublicReadForWebsite",
      Effect    = "Allow",
      Principal = "*",
      Action    = "s3:GetObject",
      Resource  = "arn:aws:s3:::${var.page_bucket}/*"
    }]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.page
  ]
}


# -------------------------
# S3 - 로그 버킷 (woong-log)
# -------------------------
resource "aws_s3_bucket" "log" {
  bucket        = var.log_bucket
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "log" {
  bucket                  = aws_s3_bucket.log.id
  block_public_acls       = true
  block_public_policy     = true
  restrict_public_buckets = true
  ignore_public_acls      = true
}

# 버킷 정책 (VPC Flow Logs + ALB Access Logs)
resource "aws_s3_bucket_policy" "log" {
  bucket = aws_s3_bucket.log.id
  policy = jsonencode({
    Version = "2012-10-17",
    Id      = "AWSLogDeliveryWrite20150319",
    Statement = [
      # VPC Flow Logs (CloudWatch Logs delivery)
      {
        Sid : "AWSLogDeliveryWrite1",
        Effect : "Allow",
        Principal : { Service : "delivery.logs.amazonaws.com" },
        Action : "s3:PutObject",
        Resource : "arn:aws:s3:::${var.log_bucket}/${var.vpc_prefix}AWSLogs/${data.aws_caller_identity.this.account_id}/*",
        Condition : {
          StringEquals : {
            "aws:SourceAccount" : data.aws_caller_identity.this.account_id,
            "s3:x-amz-acl" : "bucket-owner-full-control"
          },
          ArnLike : {
            "aws:SourceArn" : "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.this.account_id}:*"
          }
        }
      },
      {
        Sid : "AWSLogDeliveryAclCheck1",
        Effect : "Allow",
        Principal : { Service : "delivery.logs.amazonaws.com" },
        Action : "s3:GetBucketAcl",
        Resource : "arn:aws:s3:::${var.log_bucket}",
        Condition : {
          StringEquals : { "aws:SourceAccount" : data.aws_caller_identity.this.account_id },
          ArnLike : { "aws:SourceArn" : "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.this.account_id}:*" }
        }
      },
      # ALB Access Logs (서울=600734575887)
      {
        Sid : "AllowALBWriteSeoul",
        Effect : "Allow",
        Principal : { AWS : "arn:aws:iam::600734575887:root" },
        Action : "s3:PutObject",
        Resource : "arn:aws:s3:::${var.log_bucket}/${var.alb_prefix}AWSLogs/${data.aws_caller_identity.this.account_id}/*"
      }
    ]
  })
}

# -------------------------
# S3 - 플레이북 버킷 (woong-playbook)
# -------------------------
resource "aws_s3_bucket" "playbook" {
  bucket        = var.play_bucket
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_object" "playbook" {
  bucket       = var.play_bucket
  key          = var.playbook_key # 예: "cases.yaml"
  source       = "${path.root}/files/cases.yaml"
  content_type = "text/yaml"
  etag         = filemd5("${path.root}/files/cases.yaml")

  # 버킷이 먼저 있어야 함
  depends_on = [aws_s3_bucket.playbook]
}

# -------------------------
# Lambda (Function URL + CORS)
# -------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.root}/lambda/app.py"
  output_path = "${path.root}/lambda/function.zip"
}

resource "aws_iam_role" "lambda_role" {
  name = "${var.project}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_policy" "lambda_policy" {
  name = "${var.project}-lambda-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # S3 읽기
      {
        Effect : "Allow",
        Action : [
          "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"
        ],
        Resource : [
          "arn:aws:s3:::${var.log_bucket}",
          "arn:aws:s3:::${var.log_bucket}/*",
          "arn:aws:s3:::${var.play_bucket}",
          "arn:aws:s3:::${var.play_bucket}/*"
        ]
      },
      # CloudWatch Logs
      {
        Effect : "Allow",
        Action : [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"
        ],
        Resource : "*"
      },
      # Bedrock Invoke
      {
        Effect : "Allow",
        Action : [
          "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"
        ],
        Resource : "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-lambda"
  role             = aws_iam_role.lambda_role.arn
  package_type     = "Zip"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "app.handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 1536
  architectures    = ["x86_64"]

  environment {
    variables = {
      LOG_BUCKET = var.log_bucket
      ALB_PREFIX = var.alb_prefix
      VPC_PREFIX = var.vpc_prefix

      PLAYBOOK_BUCKET = var.play_bucket
      PLAYBOOK_KEY    = var.playbook_key

      MODEL_ID       = var.model_id
      BEDROCK_REGION = var.aws_region
      ALLOW_ORIGIN   = var.allow_origin

      TOP_N                = tostring(var.top_n)
      MAX_OBJECTS_PER_TYPE = tostring(var.max_objects_per_type)
      MAX_BYTES_PER_OBJECT = tostring(var.max_bytes_per_object)
      TOP_TIME_EVENTS      = tostring(var.top_time_events)
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.arn
  authorization_type = "NONE"

  cors {
    allow_origins = [var.allow_origin]
    allow_methods = ["POST"]
    allow_headers = ["content-type"]
  }
}

resource "aws_s3_object" "config_js" {
  bucket        = aws_s3_bucket.page.id
  key           = "config.js"
  content       = "window.APP_CONFIG = { API_URL: \"${aws_lambda_function_url.api.function_url}\" };"
  content_type  = "application/javascript"
  cache_control = "no-store"

  depends_on = [aws_lambda_function_url.api]

  etag = md5("window.APP_CONFIG = { API_URL: \"${aws_lambda_function_url.api.function_url}\" };")
}

# 정적 사이트에서 Lambda로 호출할 수 있도록 오리진을 외부에 알려주고 싶으면 아래 출력 참고
