resource "aws_security_group" "rds" {
  name   = "rds-sg"
  vpc_id = var.vpc_id
  tags   = var.tags

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_vpc" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = "10.0.0.0/16" # 데모: 내부 넓게 허용
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
}

resource "aws_db_subnet_group" "this" {
  name       = "woong-rds-subnet"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_db_instance" "this" {
  identifier             = "woong-mysql"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  storage_encrypted      = false
  skip_final_snapshot    = true
  deletion_protection    = false
  multi_az               = false
  tags                   = var.tags
}
