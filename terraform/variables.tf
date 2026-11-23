variable "aws_region" {
  description = "AWS region for deployment."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "devsecops-home-test"
}

variable "environment" {
  type    = string
  default = "test"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "image_tag" {
  description = "Use an immutable commit SHA tag in deployment."
  type        = string
  default     = "latest"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "acm_certificate_arn" {
  description = "An ACM certificate ARN in the same region as the ALB. Required for HTTPS listener."
  type        = string
}
