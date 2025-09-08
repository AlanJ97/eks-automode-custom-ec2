variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "Name for the resources, used for tagging"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets"
  type        = list(string)
}

variable "availability_zones" {
  description = "List of Availability Zones to use"
  type        = list(string)
}
