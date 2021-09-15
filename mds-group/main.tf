terraform {
  required_version = ">= 0.12" # templatefile function
}

locals {
  built_installer_url = "http://packages.couchbase.com/releases/${var.couchbase_version}/couchbase-server-${var.couchbase_edition}-${var.couchbase_version}-amzn2.x86_64.rpm"
  installer_url       = coalesce(var.installer_url, local.built_installer_url)

  major_version = element(split(".", var.couchbase_version), 0)
  minor_version = element(split(".", var.couchbase_version), 1)
}

resource "aws_launch_configuration" "node" {
  count = var.node_count > 0 ? 1 : 0

  name_prefix       = replace("${var.cluster_name} ${var.name}", " ", "-")
  image_id          = local.ami
  instance_type     = var.instance_type
  enable_monitoring = var.detailed_monitoring

  key_name                    = var.key_pair_name
  security_groups             = var.security_group_ids
  iam_instance_profile        = var.iam_instance_profile
  associate_public_ip_address = var.topology == "public"

  root_block_device {
    volume_type = var.boot_volume.volume_type
    volume_size = var.boot_volume.volume_size
  }

  ebs_block_device {
    device_name = "/dev/sdb"
    volume_type = var.data_volume.volume_type
    volume_size = var.data_volume.volume_size
  }

  ebs_optimized     = var.ebs_optimized

  placement_tenancy = var.placement_tenancy

  user_data = templatefile("${path.module}/userdata.tpl.sh", {
    region            = data.aws_region.current.name
    apply_updates     = var.apply_updates ? "echo \"Applying updates...\"\nyum update -y": "echo \"Skipping updates\""
    installer_url     = local.installer_url
    couchbase_edition = var.couchbase_edition

    topology                   = var.topology
    cluster_name               = var.cluster_name
    cluster_name_init          = local.major_version >= 5 ? var.cluster_name : ""
    cluster_admin_username     = var.cluster_admin_username
    cluster_admin_password     = var.cluster_admin_password
    index_storage              = var.cluster_index_storage
    data_ramsize               = var.cluster_ram_size["data"]
    index_ramsize              = var.cluster_ram_size["index"]
    fts_ramsize                = var.cluster_ram_size["fts"]
    analytics_ramsize          = lookup(var.cluster_ram_size, "analytics", 0)
    services                   = join(",", var.services)
    analytics_paths            = contains(var.services, "analytics") ? join(" ", formatlist("--node-init-analytics-path $DATADIR/analytics%s", var.analytics_mpp)) : ""
    rally_autoscaling_group_id = var.rally_autoscaling_group_id

    additional_initialization_script = var.additional_initialization_script
    auto_rebalance                   = var.auto_rebalance
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "node" {
  count = var.node_count > 0 ? 1 : 0

  name_prefix          = replace("${var.cluster_name} ${var.name}", " ", "-")
  launch_configuration = aws_launch_configuration.node.*.name[count.index]
  desired_capacity     = var.node_count
  min_size             = 1
  max_size             = 100
  vpc_zone_identifier  = var.subnet_ids

  # Prevent AZ imbalance from resulting in an unexpected termination
  # It needs to be a manual process with rebalances in Couchbase
  suspended_processes = ["AZRebalance"]

  # Don't wait for instances to start
  # This allows the use of https://github.com/brantburnett/terraform-aws-autoscaling-route53-srv
  wait_for_capacity_timeout = 0

  tag {
    key = "Name"
    value = "${var.cluster_name} ${var.name}"
    propagate_at_launch = true
  }

  tag {
    key = "Services"
    value = join(",", var.services)
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key = tag.value.key
      value = tag.value.value
      propagate_at_launch = tag.value.propagate_at_launch
    }
  }
}

data "aws_region" "current" {}
