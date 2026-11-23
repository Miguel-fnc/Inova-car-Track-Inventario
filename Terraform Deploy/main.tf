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

  scaling_subnet_ids = sort([
    for subnet_id in data.aws_subnets.default.ids : subnet_id
    if contains(var.scaling_availability_zones, data.aws_subnet.default[subnet_id].availability_zone)
  ])
}

# Bucket privado existente usado para entregar el sitio y el backend a las instancias.
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

data "aws_ec2_managed_prefix_list" "ec2_instance_connect" {
  name = "com.amazonaws.${var.aws_region}.ec2-instance-connect"
}

resource "aws_security_group" "ec2" {
  name        = "${local.common_name}-ec2"
  description = "Only ALB and EC2 Instance Connect can reach the application instances"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow outbound traffic to Supabase and AWS services"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${local.common_name}-alb"
  description = "Public ALB for website and API Gateway integration"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Forward traffic to the application instances"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "cache" {
  name        = "${local.common_name}-cache"
  description = "Private Valkey cache accessible only by application instances"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow cache responses"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_public" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP for website and API Gateway integration"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "HTTP from the public application ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "ssh_from_ec2_instance_connect" {
  security_group_id = aws_security_group.ec2.id
  description       = "SSH only from the AWS EC2 Instance Connect service"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.ec2_instance_connect.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_ec2" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.ec2.id
  description                  = "Valkey only from the application instances"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_elasticache_subnet_group" "cache" {
  name       = "${local.common_name}-cache-subnets"
  subnet_ids = local.scaling_subnet_ids
}

resource "aws_elasticache_replication_group" "cache" {
  replication_group_id       = "${var.project_name}-${data.aws_caller_identity.current.account_id}-cache"
  description                = "Shared Valkey cache for Inova Car application instances"
  engine                     = "valkey"
  node_type                  = var.cache_node_type
  port                       = 6379
  num_cache_clusters         = var.cache_node_count
  automatic_failover_enabled = var.cache_node_count > 1
  multi_az_enabled           = var.cache_node_count > 1
  subnet_group_name          = aws_elasticache_subnet_group.cache.name
  security_group_ids         = [aws_security_group.cache.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false
  apply_immediately          = true
}

resource "aws_lb" "app" {
  name               = "${var.project_name}-${substr(data.aws_caller_identity.current.account_id, 0, 8)}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.scaling_subnet_ids

  tags = {
    Name = "${local.common_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.project_name}-${substr(data.aws_caller_identity.current.account_id, 0, 8)}-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.default.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/api/live"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "${local.common_name}-app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = data.aws_iam_instance_profile.lab.name
  }

  network_interfaces {
    associate_public_ip_address = true
    device_index                = 0
    security_groups             = [aws_security_group.ec2.id]
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    bucket_name    = data.aws_s3_bucket.artifacts.bucket
    aws_region     = var.aws_region
    cache_endpoint = aws_elasticache_replication_group.cache.primary_endpoint_address
  }))

  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.common_name}-app"
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${local.common_name}-asg"
  min_size                  = var.asg_min_size
  desired_capacity          = var.asg_desired_capacity
  max_size                  = var.asg_max_size
  vpc_zone_identifier       = local.scaling_subnet_ids
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  wait_for_capacity_timeout = "15m"

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  tag {
    key                 = "Name"
    value               = "${local.common_name}-app"
    propagate_at_launch = true
  }

  depends_on = [aws_lb_listener.app]
}

resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.common_name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.asg_target_cpu
  }
}

resource "aws_apigatewayv2_api" "inventory" {
  name          = "${local.common_name}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = ["http://${aws_lb.app.dns_name}"]
    allow_methods  = ["GET", "POST", "OPTIONS"]
    allow_headers  = ["authorization", "content-type"]
    expose_headers = ["x-cache"]
    max_age        = 300
  }
}

resource "aws_apigatewayv2_integration" "inventory" {
  api_id               = aws_apigatewayv2_api.inventory.id
  integration_type     = "HTTP_PROXY"
  integration_method   = "ANY"
  connection_type      = "INTERNET"
  integration_uri      = "http://${aws_lb.app.dns_name}"
  request_parameters   = { "overwrite:path" = "$request.path" }
  timeout_milliseconds = 30000
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
