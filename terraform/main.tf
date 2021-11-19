terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }

  required_version = ">= 0.14.9"
}

provider "aws" {
  profile = "default"
  region  = "us-east-2"
}

## ECR Repository
resource "aws_ecr_repository" "hello-svc" {
  name = "hello-svc"
}

## ECS Cluster
resource "aws_ecs_cluster" "edgars_cluster" {
    name = "edgars-cluster"
}

# ECS Task
resource "aws_ecs_task_definition" "hello-svc-task" {
  for_each = var.environments
  family                   = "hello-svc-${each.key}"
  container_definitions    = <<DEFINITION
  [
    {
      "name": "hello-svc-${each.key}",
      "image": "${aws_ecr_repository.hello-svc.repository_url}",
      "essential": true,
      "environment": [
          {
              "name": "ENV",
              "value": "${each.key}"
          }
      ],
      "portMappings": [
        {
          "containerPort": 8080,
          "hostPort": 8080
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 512
  cpu                      = 256
  execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# VPC Resources
resource "aws_default_vpc" "default_vpc" {
}

# Providing a reference to our default subnets
resource "aws_default_subnet" "default_subnet_a" {
  availability_zone = "us-east-2a"
}

resource "aws_default_subnet" "default_subnet_b" {
  availability_zone = "us-east-2b"
}

resource "aws_default_subnet" "default_subnet_c" {
  availability_zone = "us-east-2c"
}

# ECS Services
resource "aws_ecs_service" "hello_svc" {
  for_each = var.environments
  name            = "hello-svc-${each.key}"
  cluster         = "${aws_ecs_cluster.edgars_cluster.id}"
  task_definition = "${aws_ecs_task_definition.hello-svc-task[each.key].arn}"
  launch_type     = "FARGATE"
  desired_count   = each.key == "production" ? 3 : 1

  load_balancer {
    target_group_arn = "${aws_lb_target_group.target_group[each.key].arn}"
    container_name   = "${aws_ecs_task_definition.hello-svc-task[each.key].family}"
    container_port   = 8080
  }

  network_configuration {
    subnets          = ["${aws_default_subnet.default_subnet_a.id}", "${aws_default_subnet.default_subnet_b.id}", "${aws_default_subnet.default_subnet_c.id}"]
    assign_public_ip = true # Providing our containers with public IPs
    security_groups = ["${aws_security_group.service_security_group.id}"]
  }
}

# ECS Service SG
resource "aws_security_group" "service_security_group" {
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ALB 
resource "aws_alb" "application_load_balancer" {
  for_each = var.environments
  name               = "hello-svc-${each.key}-alb"
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    "${aws_default_subnet.default_subnet_a.id}",
    "${aws_default_subnet.default_subnet_b.id}",
    "${aws_default_subnet.default_subnet_c.id}"
  ]
  # Referencing the security group
  security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
}

# ALB SG
resource "aws_security_group" "load_balancer_security_group" {
  ingress {
    from_port   = 80
    to_port     = 8080
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

resource "aws_lb_target_group" "target_group" {
  for_each = var.environments
  name        = "${each.key}-target-group"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${aws_default_vpc.default_vpc.id}"
  health_check {
    matcher = "200,301,302"
    path = "/hello"
  }
}

resource "aws_lb_listener" "listener" {
  for_each = var.environments
  load_balancer_arn = "${aws_alb.application_load_balancer[each.key].arn}"
  port              = "80"
  protocol          = "HTTP"
  # certificate_arn   = aws_acm_certificate_validation.cert_validation.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.target_group[each.key].arn}"
  }
}

# resource "aws_acm_certificate" "cert" {
#   domain_name       = "edgarochoa.com"
#   validation_method = "DNS"

#   lifecycle {
#     create_before_destroy = true
#   }
# }

# resource "aws_route53_zone" "hosted_zone" {
#   name         = "edgarochoa.com"
# }

# resource "aws_route53_record" "record" {
#   for_each = {
#     for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
#       name   = dvo.resource_record_name
#       record = dvo.resource_record_value
#       type   = dvo.resource_record_type
#     }
#   }

#   allow_overwrite = true
#   name            = each.value.name
#   records         = [each.value.record]
#   ttl             = 60
#   type            = each.value.type
#   zone_id         = aws_route53_zone.hosted_zone.zone_id
# }

# resource "aws_acm_certificate_validation" "cert_validation" {
#   certificate_arn         = aws_acm_certificate.cert.arn
#   validation_record_fqdns = [for record in aws_route53_record.record : record.fqdn]
# }