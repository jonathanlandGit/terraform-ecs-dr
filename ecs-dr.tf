# -------------------- PROVIDER --------------------
provider "aws" {
  region = "us-east-1"
}

# -------------------- VPC --------------------
resource "aws_vpc" "dr_test_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

# -------------------- AVAILABILITY ZONES --------------------
data "aws_availability_zones" "available" {}

# -------------------- SUBNETS --------------------
resource "aws_subnet" "az1a" {
  vpc_id                  = aws_vpc.dr_test_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "az2a" {
  vpc_id                  = aws_vpc.dr_test_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
}

# NEW THIRD SUBNET
resource "aws_subnet" "az3a" {
  vpc_id                  = aws_vpc.dr_test_vpc.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = data.aws_availability_zones.available.names[2]
  map_public_ip_on_launch = true
}

locals {
  ecs_subnets = [
    aws_subnet.az1a.id,
    aws_subnet.az2a.id,
    aws_subnet.az3a.id, # added
  ]

  ecs_services = {
    "dr-test-service-1" = { image = "nginx:latest", containerPort = 80 }
    "dr-test-service-2" = { image = "httpd:latest", containerPort = 80 }
    "dr-test-service-3" = { image = "nginx:latest", containerPort = 80 }
    "dr-test-service-4" = { image = "nginx:latest", containerPort = 80 }
  }
}

# -------------------- INTERNET GATEWAY & ROUTE TABLE --------------------
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.dr_test_vpc.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.dr_test_vpc.id
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "az1a_assoc" {
  subnet_id      = aws_subnet.az1a.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "az2a_assoc" {
  subnet_id      = aws_subnet.az2a.id
  route_table_id = aws_route_table.rt.id
}

# NEW ROUTE TABLE ASSOCIATION FOR THIRD SUBNET
resource "aws_route_table_association" "az3a_assoc" {
  subnet_id      = aws_subnet.az3a.id
  route_table_id = aws_route_table.rt.id
}

# -------------------- ECS CLUSTER --------------------
resource "aws_ecs_cluster" "dr_test_cluster" {
  name = "dr-test-cluster"
}

# -------------------- SECURITY GROUPS --------------------
resource "aws_security_group" "ecs_sg" {
  name        = "dr-test-ecs-sg"
  vpc_id      = aws_vpc.dr_test_vpc.id
  description = "Allow traffic for ECS tasks"

  ingress {
    from_port   = 0
    to_port     = 65535
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

# NEW EXTRA SECURITY GROUP
resource "aws_security_group" "ecs_sg_extra" {
  name        = "dr-test-ecs-sg-extra"
  vpc_id      = aws_vpc.dr_test_vpc.id
  description = "Additional SG for ECS DR testing"

  ingress {
    from_port   = 0
    to_port     = 65535
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

# -------------------- ECS TASK DEFINITIONS --------------------
resource "aws_ecs_task_definition" "dr_test_tasks" {
  for_each                 = local.ecs_services
  family                   = each.key
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = each.value.image
      essential = true
      portMappings = [
        {
          containerPort = each.value.containerPort
          hostPort      = each.value.containerPort
        }
      ]
    }
  ])
}

# -------------------- APPLICATION LOAD BALANCER --------------------
resource "aws_lb" "dr_test_alb" {
  name               = "dr-test-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = local.ecs_subnets # now includes all 3 subnets
}

# -------------------- TARGET GROUPS --------------------
resource "aws_lb_target_group" "dr_test_tg" {
  for_each = local.ecs_services

  name        = each.key
  port        = each.value.containerPort
  protocol    = "HTTP"
  vpc_id      = aws_vpc.dr_test_vpc.id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    path                = "/"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# -------------------- ALB LISTENER --------------------
resource "aws_lb_listener" "dr_test_listener" {
  load_balancer_arn = aws_lb.dr_test_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# -------------------- LISTENER RULES --------------------
resource "aws_lb_listener_rule" "dr_test_rules" {
  for_each     = local.ecs_services
  listener_arn = aws_lb_listener.dr_test_listener.arn
  priority     = 100 + index(keys(local.ecs_services), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dr_test_tg[each.key].arn
  }

  condition {
    path_pattern {
      values = ["/${each.key}*"]
    }
  }
}

# -------------------- ECS SERVICES --------------------
resource "aws_ecs_service" "dr_test_services" {
  for_each        = local.ecs_services
  name            = each.key
  cluster         = aws_ecs_cluster.dr_test_cluster.id
  task_definition = aws_ecs_task_definition.dr_test_tasks[each.key].arn
  desired_count   = 3
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.ecs_subnets
    assign_public_ip = true
    security_groups = [
      aws_security_group.ecs_sg.id,
      aws_security_group.ecs_sg_extra.id, # added extra SG
    ]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.dr_test_tg[each.key].arn
    container_name   = each.key
    container_port   = each.value.containerPort
  }

  depends_on = [aws_lb_listener_rule.dr_test_rules]
}

# -------------------- SNS TOPIC FOR ALERTS --------------------
resource "aws_sns_topic" "dr_alerts" {
  name = "dr-alerts-topic"
}

resource "aws_sns_topic_subscription" "dr_email_subscriptions" {
  count     = 1
  topic_arn = aws_sns_topic.dr_alerts.arn
  protocol  = "email"
  endpoint  = ["jonathanland.git@gmail.com"][count.index]
}

# -------------------- EVENTBRIDGE RULE & TARGET --------------------
resource "aws_cloudwatch_event_rule" "ecs_failover_rule" {
  name        = "ecs-dr-failover"
  description = "Triggers when ECS service is updated (failover or restore)"
  event_pattern = jsonencode({
    "source" : ["aws.ecs"],
    "detail-type" : ["ECS Service Action"]
  })
}

resource "aws_cloudwatch_event_target" "ecs_failover_sns_target" {
  rule      = aws_cloudwatch_event_rule.ecs_failover_rule.name
  target_id = "sns-dr-alerts"
  arn       = aws_sns_topic.dr_alerts.arn
}

resource "aws_sns_topic_policy" "allow_eventbridge" {
  arn = aws_sns_topic.dr_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.dr_alerts.arn
      }
    ]
  })
}

# -------------------- OUTPUTS --------------------
output "alb_dns_name" {
  value = aws_lb.dr_test_alb.dns_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.dr_alerts.arn
}
