variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type    = string
  default = "default"
}

variable "project" {
  type    = string
  default = "aws-log-chatbot"
}

variable "page_bucket" {
  type = string
}

variable "log_bucket" {
  type = string
}

variable "play_bucket" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "model_id" {
  type    = string
  default = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "alb_prefix" {
  type    = string
  default = "alb/"
}

variable "vpc_prefix" {
  type    = string
  default = "vpcflow/"
}

variable "playbook_key" {
  type    = string
  default = "cases.yaml"
}

variable "allow_origin" {
  type    = string
  default = "*"
}

variable "top_n" {
  type    = number
  default = 5
}

variable "max_objects_per_type" {
  type    = number
  default = 20
}

variable "max_bytes_per_object" {
  type    = number
  default = 10485760
}

variable "top_time_events" {
  type    = number
  default = 2000
}
