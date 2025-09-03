# Configure the AWS provider
# Replace 'us-east-1' with your desired region
provider "aws" {
  region = "us-east-1"
}

# Configure the AAP provider
# Replace with your AAP instance details
terraform {
  required_version = "~> v1.14.0"
  required_providers {
    aap = {
      source = "dleehr/aap"
      version = "2.0.0-demo1"
    }
  }
}

provider "aap" {
  host     = var.aap_host
  username = var.aap_username
  password = var.aap_password
}

# Variable to store the public key for the EC2 instance
variable "ssh_key_name" {
  description = "The name of the key pair for the EC2 instance"
  type        = string
}

# Variable to store the AAP details
variable "aap_host" {
  description = "The URL of the Ansible Automation Platform instance"
  type        = string
}

variable "aap_username" {
  description = "The username for the AAP instance"
  type        = string
  sensitive   = true
}

variable "aap_password" {
  description = "The password for the AAP instance"
  type        = string
  sensitive   = true
}

variable "aap_job_template_id" {
  description = "The ID of the Job Template in AAP to run"
  type        = number
}

# 1. Provision the AWS EC2 instance
resource "aws_instance" "web_server" {
  ami           = "ami-0a7d80731ae1b2435" # Ubuntu Server 22.04 LTS (HVM)
  instance_type = "t2.micro"
  key_name      = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.allow_http_ssh.id]
  tags = {
    Name = "hcp-terraform-aap-demo"
  }
}

# Security group to allow SSH and HTTP traffic
resource "aws_security_group" "allow_http_ssh" {
  name_prefix = "allow_http_ssh_"
  description = "Allow SSH, HTTP inbound and all outbound traffic"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Add this rule to allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols (TCP, UDP, ICMP, etc.)
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Configure AAP resources to run the playbook

# Create a dynamic inventory in AAP
resource "aap_inventory" "dynamic_inventory" {
  name        = "Terraform Provisioned Inventory"
  description = "Inventory for hosts provisioned by Terraform"
}

# Add the new EC2 instance to the dynamic inventory
resource "aap_host" "new_host" {
  inventory_id = aap_inventory.dynamic_inventory.id
  name         = aws_instance.web_server.public_ip
  description  = "Host provisioned by Terraform"
  variables    = jsonencode({
    ansible_user = "ubuntu"
  })
}

# Wait for the EC2 instance to be ready before proceeding
resource "null_resource" "wait_for_instance" {
  # This resource will wait until the EC2 instance is created
  depends_on = [aws_instance.web_server]

  # The provisioner will run a simple shell command that waits for port 22 to be available.
  provisioner "local-exec" {
    command = "until `timeout 1 bash -c 'cat < /dev/null > /dev/tcp/${aws_instance.web_server.public_ip}/22'`; do echo 'Waiting for port 22...'; sleep 5; done"
  }
}

# The AAP job now depends on the null_resource, which will only complete
# after the EC2 instance is ready for SSH connections.
resource "aap_job" "run_webserver_playbook" {
  job_template_id = var.aap_job_template_id
  inventory_id    = aap_inventory.dynamic_inventory.id
  depends_on      = [null_resource.wait_for_instance]
}

# Output the public IP of the new instance
output "web_server_public_ip" {
  value = aws_instance.web_server.public_ip
}
