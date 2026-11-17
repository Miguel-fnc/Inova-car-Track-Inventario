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

