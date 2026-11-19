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

# Prefijo administrado por AWS para EC2 Instance Connect en esta región.
data "aws_ec2_managed_prefix_list" "ec2_instance_connect" {
  name = "com.amazonaws.${var.aws_region}.ec2-instance-connect"
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

resource "aws_vpc_security_group_ingress_rule" "ssh_from_ec2_instance_connect" {
  security_group_id = aws_security_group.ec2.id
  description       = "SSH only from the AWS EC2 Instance Connect service"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.ec2_instance_connect.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
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

# API Gateway publica la API y reenvía las rutas completas a Nginx en la EC2.
resource "aws_apigatewayv2_api" "inventory" {
  name          = "${local.common_name}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = ["http://${aws_instance.web.public_ip}"]
    allow_methods  = ["GET", "POST", "OPTIONS"]
    allow_headers  = ["authorization", "content-type"]
    expose_headers = ["x-cache"]
    max_age        = 300
  }
}

resource "aws_apigatewayv2_integration" "inventory" {
  api_id                 = aws_apigatewayv2_api.inventory.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = "http://${aws_instance.web.public_ip}"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.inventory.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.inventory.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.inventory.id
  name        = "$default"
  auto_deploy = true
}



