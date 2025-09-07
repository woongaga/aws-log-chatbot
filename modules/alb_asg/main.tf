resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "ALB"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  name        = "ec2-sg"
  description = "App"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  owners      = ["099720109477"]
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_lb" "this" {
  name               = "woong-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  access_logs {
    bucket  = var.log_bucket
    prefix  = "alb"
    enabled = true
  }

  tags = var.tags
}

resource "aws_lb_target_group" "tg" {
  name     = "woong-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    path                = "/"
    matcher             = "200-399"
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

locals {
  user_data = base64encode(<<-EOS
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx php-fpm php-mysql mysql-client

    # PHP-FPM 소켓 경로 확인 (Ubuntu 22.04 기본: php8.1-fpm)
    PHPFPM=php8.1-fpm
    systemctl enable $${PHPFPM}
    systemctl restart $${PHPFPM}

    # Nginx 기본 사이트에 index.php 처리 추가 및 index 우선순위 설정
    cat >/etc/nginx/sites-available/default <<'NGINX'
    server {
      listen 80 default_server;
      listen [::]:80 default_server;

      root /var/www/html;
      index index.php index.html;

      server_name _;

      location / {
        try_files $uri $uri/ =404;
      }

      location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
      }

      location ~ /\.ht {
        deny all;
      }
    }
    NGINX

    # 헬스 체크용 정적 파일
    echo "ok" >/var/www/html/health

    # 샘플 index.php (RDS 연결 시도)
    cat >/var/www/html/index.php <<'PHP'
    <?php
      $mysqli = @new mysqli("${var.db_endpoint}", "${var.db_username}", "${var.db_password}", "${var.db_name}");
      if ($mysqli->connect_errno) {
        http_response_code(500);
        echo "DB connect error: " . $mysqli->connect_error;
      } else {
        $res = $mysqli->query("SELECT NOW() as nowtime");
        $row = $res->fetch_assoc();
        echo "DB Connected! NOW(): " . $row["nowtime"];
      }
    ?>
    PHP

    chown -R www-data:www-data /var/www/html
    rm -f /var/www/html/index.nginx-debian.html

    systemctl enable nginx
    systemctl restart nginx
  EOS
  )
}


resource "aws_launch_template" "lt" {
  name_prefix   = "woong-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"

  user_data = local.user_data

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags          = var.tags
  }
}

resource "aws_autoscaling_group" "asg" {
  name                      = "woong-asg"
  min_size                  = 2
  max_size                  = 2
  desired_capacity          = 2
  vpc_zone_identifier       = var.private_subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.tg.arn]

  tag {
    key                 = "Name"
    value               = "woong-asg-ec2"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
