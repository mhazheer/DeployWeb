provider "aws" {
  region = "eu-west-1"
}

# Variables normalement dans un autre fichier (variables.tf) mais pour faire simple.... ca marche aussi !!!
variable "env" {
  type    = string
  default = "dev"
}

####################################################################
# On recherche la derniere AMI créée avec le Name TAG PackerAnsible-Apache
data "aws_ami" "selected" {
  owners = ["self"]
  filter {
    name   = "state"
    values = ["available"]

  }
  filter {
    name   = "tag:Name"
    values = ["PackerAnsible-Apache"]
  }
  most_recent = true
}

# On recupere les ressources reseau
## VPC

#data "aws_vpc" "selected" {
 # tags = {
#    Name = "${var.env}-vpc"
#  }
#}
data "aws_vpc" "selected" {
filter {
    name   = "tag:Name"
    values = ["${var.env}-vpc"]
  }
}
## Subnets
data "aws_subnet" "subnet-public-1" {
  tags = {
    Name = "${var.env}-subnet-public-1"
  }
}

data "aws_subnet" "subnet-public-2" {
  tags = {
    Name = "${var.env}-subnet-public-2"

  }
}

data "aws_subnet" "subnet-public-3" {
  tags = {
    Name = "${var.env}-subnet-public-3"
  }
}

data "aws_subnet" "subnet-private-1" {
  tags = {
    Name = "${var.env}-subnet-private-1"
  }
}

data "aws_subnet" "subnet-private-2" {
  tags = {
    Name = "${var.env}-subnet-private-2"
  }
}

data "aws_subnet" "subnet-private-3" {
  tags = {
    Name = "${var.env}-subnet-private-3"
  }
}

## AZ zones de disponibilités dans la région
data "aws_availability_zones" "all" {}

########################################################################
# Security Groups
## ASG
resource "aws_security_group" "web-sg-asg" {
  name   = "${var.env}-sg-asg"
  vpc_id = data.aws_vpc.selected.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port       = 443
    protocol        = "tcp"
    to_port         = 443
    security_groups = [aws_security_group.web-sg-elb.id] # on authorise en entrée de l'ASG que le flux venant de l'ELB
  }
  lifecycle {
    create_before_destroy = true
  }
}
## ELB
resource "aws_security_group" "web-sg-elb" {
  name   = "${var.env}-sg-elb"
  vpc_id = data.aws_vpc.selected.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    protocol    = "tcp"
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]   # Normalement Ouvert sur le web sauf dans le cas d'un site web Privé(Exemple Intranet ou nous qui ne voulons pas exposer le site)
  }
  lifecycle {
    create_before_destroy = true
  }
}
##########################################################################
# ASG Launch Configuration
resource "aws_launch_configuration" "web-lc" {
  image_id      = data.aws_ami.selected.id
  instance_type = "t2.micro"
  #  key_name = ""  # Si vous voulez utiliser une KeyPair pour vous connecter aux instances
  security_groups = [aws_security_group.web-sg-asg.id]
  lifecycle {
    create_before_destroy = true
  }
}

# ASG
resource "aws_autoscaling_group" "web-asg" {
  launch_configuration = aws_launch_configuration.web-lc.id
  #availability_zones   = data.aws_availability_zones.all.names
  vpc_zone_identifier  = [data.aws_subnet.subnet-private-1.id, data.aws_subnet.subnet-private-2.id, data.aws_subnet.subnet-private-3.id]
  load_balancers       = [aws_elb.web-elb.name]
  health_check_type    = "ELB"

  max_size = 4
  min_size = 2

  tag {
    key                 = "name"
    value               = "${var.env}-asg"
    propagate_at_launch = true
  }
  lifecycle {
    create_before_destroy = true
  }
}

# ELB
resource "aws_elb" "web-elb" {
  name            = "${var.env}-elb"
  subnets         = [data.aws_subnet.subnet-public-1.id, data.aws_subnet.subnet-public-2.id, data.aws_subnet.subnet-public-3.id]
  security_groups = [aws_security_group.web-sg-elb.id]

  listener {
    instance_port     = 443
    instance_protocol = "http"
    lb_port           = 443
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    interval            = 30
    target              = "HTTP:443/"
    timeout             = 3
    unhealthy_threshold = 2
  }
  lifecycle {
    create_before_destroy = true
  }
}

######################################################################################

# Autoscaling Scale Policies
## scale up
### ASG Policy
resource "aws_autoscaling_policy" "web-cpu-policy-scaleup" {
  name                   = "web-cpu-policy"
  autoscaling_group_name = aws_autoscaling_group.web-asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = "1"
  cooldown               = "300"
  policy_type            = "SimpleScaling"
}
## CloudWatch Alarm
resource "aws_cloudwatch_metric_alarm" "web-cpu-alarm-scaleup" {
  alarm_name          = "web-cpu-alarm-ScaleUp"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "70"
  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.web-asg.name
  }
  actions_enabled = true
  alarm_actions   = [aws_autoscaling_policy.web-cpu-policy-scaleup.arn]
}

## scale down
### ASG Policy
resource "aws_autoscaling_policy" "web-cpu-policy-scaledown" {
  name                   = "web-cpu-policy-scaledown"
  autoscaling_group_name = aws_autoscaling_group.web-asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = "-1"
  cooldown               = "300"
  policy_type            = "SimpleScaling"
}

### CloudWatch Alarm
resource "aws_cloudwatch_metric_alarm" "web-cpu-alarm-scaledown" {
  alarm_name          = "web-cpu-alarm-scaledown"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "5"
  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.web-asg.name
  }
  actions_enabled = true
  alarm_actions   = [aws_autoscaling_policy.web-cpu-policy-scaledown.arn]
}

#  Outputs normalement dans un autre fichier(Outputs.tf) mais pour faire simple....
## On revoie le nom DNS de l'ELB pour s'y connecter (Compter quelques minutes avant disponibilité au premier déployement)
output "elb_dns_name" {
  description = "The DNS name of the ELB"
  value       = aws_elb.web-elb.dns_name
}
terraform {
  backend "s3"{
  }
}
