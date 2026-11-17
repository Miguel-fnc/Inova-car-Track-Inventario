data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  common_name = "${var.project_name}-${data.aws_caller_identity.current.account_id}"
  public_subnet_id = sort([
    for subnet_id in data.aws_subnets.default.ids : subnet_id
    if data.aws_subnet.default[subnet_id].map_public_ip_on_launch
  ])[0]
}

# El bucket ya existe y es propiedad de la cuenta del Learner Lab.
data "aws_s3_bucket" "artifacts" {
  bucket = "${local.common_name}-${var.aws_region}"
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = data.aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = data.aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_instance_profile" "lab" {
  name = var.instance_profile_name
}

resource "aws_security_group" "ec2" {
  name        = "${local.common_name}-ec2"
  description = "Public HTTP access for the website EC2"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "http_public" {
  security_group_id = aws_security_group.ec2.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_instance" "web" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = local.public_subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    bucket_name = data.aws_s3_bucket.artifacts.bucket
    aws_region  = var.aws_region
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${local.common_name}-web"
  }

  depends_on = [
    aws_s3_bucket_public_access_block.artifacts,
    aws_s3_bucket_server_side_encryption_configuration.artifacts,
    aws_vpc_security_group_ingress_rule.http_public
  ]
}



