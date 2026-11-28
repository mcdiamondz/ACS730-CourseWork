# AMI lookup for AL2023
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id = data.aws_ssm_parameter.al2023.value
}

resource "aws_instance" "web" {
  count                  = var.instance_count
  ami                    = local.ami_id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.web.id]
  subnet_id              = aws_subnet.public[keys(local.public_subnets)[0]].id

  iam_instance_profile = "LabInstanceProfile"

  # User data to install and configure nginx
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf -y install nginx
    echo "<h1>ACS730 Assignment 1 - ${local.name}</h1>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT

  depends_on = [aws_route_table_association.public]

  tags = merge(local.common_tags, { Name = "${local.name}-web-${count.index}" })
}

# Optional artifact bucket
resource "aws_s3_bucket" "artifacts" {
  count = var.create_artifact_bucket ? 1 : 0

  bucket        = "${local.name}-artifacts"
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${local.name}-artifacts" })
}
