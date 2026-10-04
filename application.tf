data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-vpc"]
  }
}

data "aws_subnet" "public_a" {
  vpc_id     = data.aws_vpc.this.id
  cidr_block = "10.0.1.0/24"
}

data "aws_subnet" "private_a" {
  vpc_id     = data.aws_vpc.this.id
  cidr_block = "10.0.2.0/24"
}

data "aws_subnet" "public_b" {
  vpc_id     = data.aws_vpc.this.id
  cidr_block = "10.0.3.0/24"
}

data "aws_subnet" "private_b" {
  vpc_id     = data.aws_vpc.this.id
  cidr_block = "10.0.4.0/24"
}

data "aws_security_group" "ec2" {
  name   = "${var.project_name}-ec2_sg"
  vpc_id = data.aws_vpc.this.id
}

data "aws_security_group" "http" {
  name   = "${var.project_name}-http_sg"
  vpc_id = data.aws_vpc.this.id
}

data "aws_security_group" "alb" {
  name   = "${var.project_name}-sglb"
  vpc_id = data.aws_vpc.this.id
}


data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}


resource "aws_launch_template" "this" {
  name          = "${var.project_name}-template"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  key_name      = "${var.project_name}-keypair"

  iam_instance_profile {
    name = "${var.project_name}-instance_profile"
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true

    security_groups = [
      data.aws_security_group.ec2.id,
      data.aws_security_group.http.id
    ]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    
    dnf install -y httpd jq

    TOKEN=$(curl -X PUT \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token)

    INSTANCE_ID=$(curl \
      -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id)

    PRIVATE_IP=$(curl \
      -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/local-ipv4)

    cat > /var/www/html/index.html <<HTML
        Instance ID: $INSTANCE_ID
        Private IP: $PRIVATE_IP
    HTML

    systemctl enable httpd
    systemctl start httpd

    dnf update -y
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project_name}-application"
    }
  }
}


resource "aws_autoscaling_group" "this" {
  name = "${var.project_name}-asg"

  desired_capacity = var.desired_capacity
  min_size         = var.min_size
  max_size         = var.max_size

  vpc_zone_identifier = [
    data.aws_subnet.public_a.id,
    data.aws_subnet.public_b.id
  ]

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  lifecycle {
    ignore_changes = [load_balancers, target_group_arns]
  }

  tag {
    key                 = "Terraform"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }
}


resource "aws_lb_target_group" "this" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.this.id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb" "this" {
  name               = "${var.project_name}-loadbalancer"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    data.aws_security_group.alb.id
  ]

  subnets = [
    data.aws_subnet.public_a.id,
    data.aws_subnet.public_b.id
  ]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_autoscaling_attachment" "this" {
  autoscaling_group_name = aws_autoscaling_group.this.name
  lb_target_group_arn    = aws_lb_target_group.this.arn
}
