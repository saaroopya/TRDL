variable "region" {
  description = "AWS region for the cluster"
  type        = string
  default     = "eu-north-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "trdl-cluster"
}

variable "instance_type" {
  description = "EC2 instance type for cluster nodes"
  type        = string
  default     = "t3.small"
}

variable "nodes_per_az" {
  description = "Number of nodes per availability zone (total = this × 3)"
  type        = number
  default     = 1
}
