variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}

# arn:aws:s3:::<log-bucket>/<vpc-prefix>
variable "vpc_flow_s3_arn_with_prefix" {
  type = string
}
