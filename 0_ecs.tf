provider "aws" {
  region  = "eu-west-1"
  version = "~> 2.0"
}

resource "aws_ecs_cluster" "sheepit-cluster" {
  name = "sheepit-cluster"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "sheepit-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  assign_generated_ipv6_cidr_block = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_vpn_gateway = true

  manage_default_network_acl = true
  public_dedicated_network_acl = true

  public_subnet_tags = {
    Name = "overridden-name-public"
  }

  tags = {
    Owner       = "user"
    Environment = "dev"
  }

  vpc_tags = {
    Name = "vpc-name"
  }
}

data "template_file" "user_data" {
  template = "${file("${path.module}/user_data.yaml")}"

  vars = {
    ecs_cluster = "sheepit-cluster"
  }
}

resource "aws_iam_role" "ecs_agent" {
  name               = "ecs-agent"
  assume_role_policy = "${data.aws_iam_policy_document.ecs_agent.json}"
}

data "aws_iam_policy_document" "ecs_agent" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecs_agent" {
  role       = "${aws_iam_role.ecs_agent.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_agent" {
  name = "ecs-agent"
  role = "${aws_iam_role.ecs_agent.name}"
}

resource "aws_security_group" "allow_all" {
  name        = "allow_all"
  description = "Allow all traffic"
  vpc_id      = "${module.vpc.vpc_id}"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

resource "aws_launch_configuration" "sheepit-launch-configration" {
  name                 = "sheepit-launch-configration"
  image_id             = "ami-04a084a6d17d9816e"
  iam_instance_profile = "${aws_iam_instance_profile.ecs_agent.name}"
  security_groups      = ["${aws_security_group.allow_all.id}"]
  user_data            = "${data.template_file.user_data.rendered}"
  key_name             = "sheepit-aws-key"
  associate_public_ip_address = true

  instance_type = "t2.micro"
}

resource "aws_autoscaling_group" "sheepit-autoscaling-group" {
  name = "sheepit-autoscaling-group"
  vpc_zone_identifier  = "${module.vpc.public_subnets}"
  launch_configuration = "${aws_launch_configuration.sheepit-launch-configration.name}"

  desired_capacity = 1
  min_size         = 0
  max_size         = 1

  health_check_grace_period = 0
}

resource "aws_ecs_task_definition" "sheepit-backend" {
  family                = "sheepit-backend"
  container_definitions = "${file("task_definitions/sheepit-backend.json")}"
  network_mode = "bridge"

  volume {
    name      = "sheepit-volume"
    docker_volume_configuration {
      autoprovision = true
      scope = "shared"
      driver = "local"
    }
  }

  volume {
    name      = "mongo-volume"
    docker_volume_configuration {
      autoprovision = true
      scope = "shared"
      driver = "local"
    }
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.availability-zone in [eu-west-1a, eu-west-1b]"
  }
}

resource "aws_ecs_service" "sheepit-backend-service" {
  name = "sheepit-backend-service"
  cluster = "${aws_ecs_cluster.sheepit-cluster.arn}"
  task_definition = "${aws_ecs_task_definition.sheepit-backend.arn}"
  desired_count = 1
}