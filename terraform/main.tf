# Configure the AWS provider
provider "aws" {
  region = "us-east-1"
}

# Configure the AAP provider
# Using the AAP provider with Actions
terraform {
  required_version = "~> v1.14.0"
  required_providers {
    aap = {
      source = "ansible/aap"
      version = "1.4.0-devpreview1"
    }
  }
}

provider "aap" {
  host     = var.aap_host
  insecure_skip_verify = true
  username = var.aap_username
  password = var.aap_password
}

# Variable to store the public key for the EC2 instance
variable "ssh_key_name" {
  description = "The name of the key pair for the EC2 instance"
  type        = string
}

# Variable to store the URL for the AAP Event Stream
variable "aap_eventstream_url" {
  description = "The URL of the AAP Event Stream"
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

variable "tf-es-username" {
  description = "The username for the AAP instance"
  type        = string
  sensitive   = true
}

variable "tf-es-password" {
  description = "The username for the AAP instance"
  type        = string
  sensitive   = true
}

variable "aap_password" {
  description = "The password for the AAP instance"
  type        = string
  sensitive   = true
}

#variable "aap_job_template_id" {
#  description = "The ID of the Job Template in AAP to run"
#  type        = number
#}

resource "aws_security_group" "allow_http_ssh" {
  name        = "web-server-sg"
#  name_prefix = "allow_http_ssh_"
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
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 1. Provision the AWS EC2 instance(s)
resource "aws_instance" "web_server" {
  count                     = 5
  ami                       = "ami-0dfc569a8686b9320" # Red Hat Enterprise Linux 9 (HVM)
  instance_type             = "t2.micro"
  key_name                  = var.ssh_key_name
  vpc_security_group_ids    = [aws_security_group.allow_http_ssh.id]
  associate_public_ip_address = true
  tags = {
    Name = "hcp-terraform-aap-demo-${count.index + 1}"
    owner = "hmourad"
  }
  
  lifecycle {
    # This action triggers syntax new in terraform
    # It configures terraform to run the listed actions based
    # on the named lifecycle events: "After creating this resource, run the action"
    action_trigger {
      events  = [after_create]
      actions = [action.aap_eda_eventstream_post.create]
    }
  }
}

# 2. Configure AAP resources to run the playbook

# This is the inventory in AAP we are using
data "aap_inventory" "inventory" {
  name        = "Terraform Provisioned Inventory"
  organization_name = "Default"
}

# Create some infrastructure - inventory group - that has an action tied to it
resource "aap_group" "tfademo" {
  name = "tfademo"
  inventory_id = data.aap_inventory.inventory.id
}

# Add the new EC2 instance to the inventory
resource "aap_host" "host" {
  for_each     = { for idx, instance in aws_instance.web_server : idx => instance }
  inventory_id = data.aap_inventory.inventory.id
  groups = toset([resource.aap_group.tfademo.id])
  name         = each.value.public_ip
  description  = "Host provisioned by Terraform"
  variables    = jsonencode({
    ansible_user = "ec2-user"
    public_ip    = each.value.public_ip
    target_hosts = each.value.public_ip
  })
  lifecycle {
    action_trigger {
      events  = [after_create]
      actions = [action.aap_eda_eventstream_post.update]
    }
  }
}

# Output the public IP of the new instance
output "web_server_public_ips" {
  value = [for instance in aws_instance.web_server : instance.public_ip]
}

# This is using a new 'aap_eda_eventstream' data source in the terraform-provider-aap POC
# The purpose is to look up an EDA Event Stream object by ID so that we know its URL when
# we want to send an event later.
#data "aap_eda_eventstream" "eventstream" {
#  name = "TF Actions Event Stream"
#}

# Sample output just to show that we looked up the Event Stream URL with the above datasource
# output "event_stream_url" {
#  value = data.aap_eventstream.eventstream.url
#}

# This is using a new 'aap_eda_eventstream_post' action in the terraform-provider-aap POC
# The purpose is to POST an event with a payload (config) when triggered, and EDA
# is configured with a rulebook to extract these details out of the config and dispatch
# a job

# TF action to run the new AWS provisioning workflow (after ec2 instance are created)
action "aap_eda_eventstream_post" "create" {
  config {
    limit = "tfademo"
    template_type = "job"
    job_template_name = "New AWS Provisioning Workflow"
    organization_name = "Default"

    event_stream_config = {
      url = var.aap_eventstream_url
      insecure_skip_verify = true
      username = var.tf-es-username
      password = var.tf-es-password
    }
  }
}

# TF action to run the update AWS provisioning job (after the hosts get added to AAP inventory)
action "aap_eda_eventstream_post" "update" {
  config {
    limit = "tfademo"
    template_type = "job"
    job_template_name = "Update AWS Provisioning Job"
    organization_name = "Default"

    event_stream_config = {
      url = var.aap_eventstream_url
      insecure_skip_verify = true
      username = var.tf-es-username
      password = var.tf-es-password
    }
  }
}
