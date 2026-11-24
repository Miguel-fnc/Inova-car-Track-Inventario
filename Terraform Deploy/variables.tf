variable "aws_region" {
  description = "AWS region for the resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short prefix used in resource names."
  type        = string
  default     = "inova-car"
}

variable "instance_type" {
  description = "Small EC2 instance type available in the Learner Lab."
  type        = string
  default     = "t3.micro"
}

variable "instance_profile_name" {
  description = "Existing EC2 instance profile provided by AWS Academy Learner Lab."
  type        = string
  default     = "LabInstanceProfile"
}

variable "scaling_availability_zones" {
  description = "Two Availability Zones with public default subnets used by the ALB and Auto Scaling Group."
  type        = list(string)
  default     = ["us-east-1c", "us-east-1f"]
}

variable "asg_min_size" {
  description = "Minimum number of application EC2 instances."
  type        = number
  default     = 2

  validation {
    condition     = var.asg_min_size >= 1
    error_message = "asg_min_size debe ser al menos 1."
  }
}

variable "asg_desired_capacity" {
  description = "Initial desired number of application EC2 instances."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of application EC2 instances."
  type        = number
  default     = 4
}

variable "asg_target_cpu" {
  description = "Average CPU target percentage used by the ASG target-tracking policy. 30% is calibrated for t3.micro: the API is I/O-bound (Valkey cache + Supabase auth), so realistic load rarely pushes CPU past 35%."
  type        = number
  default     = 30
}

variable "cache_node_type" {
  description = "ElastiCache Valkey node type for the shared application cache."
  type        = string
  default     = "cache.t3.micro"
}

variable "cache_node_count" {
  description = "Valkey nodes. Use 2 or more for Multi-AZ failover; 1 lowers lab cost but removes cache HA."
  type        = number
  default     = 2

  validation {
    condition     = var.cache_node_count >= 1 && var.cache_node_count <= 6
    error_message = "cache_node_count debe estar entre 1 y 6."
  }
}

