resource "aws_launch_configuration" "example" {
  image_id           = "ami-003c463c8207b4dfa"
  instance_type = var.instance_type
  security_groups = [aws_security_group.instance.id]
  user_data = templatefile("user-data.sh",{
    server_port = var.server_port
    db_address = data.terraform_remote_state.db.outputs.address
    db_port = data.terraform_remote_state.db.outputs.port
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"
  min_size = var.min_size
  max_size = var.max_size
  tag {
    key = "Name"
    value = var.cluster_name
    propagate_at_launch = true
  }
  
}
resource "aws_security_group" "instance" {
  name =  "${var.cluster_name}-instance"  
}

resource "aws_security_group_rule" "allow_server_http_inbound" {
  type = "ingress"
  security_group_id = aws_security_group.instance.id
  from_port = var.server_port
  to_port = var.server_port
  protocol = local.tcp_protocol
  cidr_blocks = local.all_ips
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "example" {
  name = var.cluster_name
  load_balancer_type = "application"
  subnets = data.aws_subnets.default.ids
  security_groups = [aws_security_group.alb.id]
}

locals {
  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = ["0.0.0.0/0"]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port = local.http_port
  protocol = "HTTP"
  default_action {
    type = "fixed-response" 

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code = 404
    }
  }  
}

resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"   
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port = local.http_port
  to_port =  local.http_port
  protocol = local.tcp_protocol
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_http_outbound" {
  type = "egress"
  security_group_id = aws_security_group.alb.id
  from_port = local.any_port
  to_port =  local.any_port 
  protocol = local.any_protocol
  cidr_blocks = local.all_ips 
}


resource "aws_lb_target_group" "asg" {
  name = var.cluster_name
  port = var.server_port
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default.id
  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = "200"
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100
  condition {
    path_pattern {
      values = ["*"]
    }
  }
  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }  
}

resource "aws_key_pair" "tfkeypair" {
  key_name   = "tfkeypair"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCQgNZMOZ3iCfuPkxn/DLGhzHTHnYZjvuaTxaN4ml34k0Awi4KXpRV7klGblS9QPA4lRKF3JFhZaTlwWGc1vvC1jRy6VZBeE6AMcfvc23cNfLQ+7YphyAuKwBdBoWXCOzrpcwrskC2JmoOOnYo8qbJFMdAzXUVbmVJTSD0oiN1xG/kZnkpHx2u7hM6vDBiI3S5tbouWxm03eLA3l3W1SLCLEeYPijRocDuMXXN8tBlhfmC8WDkJkez9NFKicu9XfsEQFS5QP5dC66e6gq830d54XEqx7cmNNm6HMWjPYl7B7Kt/3CyHH4tBEfaIOfsCzXowLU7N365gKBZQilDLW4BOpXIh8PY+3cPu2v+83BSJZvnPlCH7IsxmnZX4E1MOGmQsK+Gyoh3/9QhnQg7xZlbG9hxhMSZS8FrglzC5qD1MZNOPXx46unpgDKw4TFPyBZ7DYaMHQCK4vRaOFGMGpgxjxYB2odqEzV50q5o8XlRNFYZ43cWbzxUgZEtLCXO50Rk= swl@swl"
}
# data "terraform_remote_state" "db" {
#   backend = "s3"
#   config = {
#     bucket = "swl-terraform-up-and-running"
#     key = "stage/s3/terraform.tfstate"
#     region = "ap-southeast-1"
#   }
# }

# S3 backend
resource "aws_s3_bucket" "terraform_state" {
  bucket = var.db_remote_state_bucket
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-up-and-running-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}

terraform {
  backend "s3" {
    bucket         = "swl-terraform-up-and-running"
    key            = "stage/s3/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "terraform-up-and-running-locks"
    encrypt        = true
  }
}
