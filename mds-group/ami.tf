data "aws_ami" "default" {
  most_recent = true
  owners = ["amazon"]
  filter {
    name = "name"
    values = ["amzn-ami-*-x86_64-gp2"]
  }

  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
    ami = var.ami == "" ? data.aws_ami.default.id : var.ami
}
