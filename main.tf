module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.17.0"
  enabled    = var.enabled
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

#
# Security Group Resources
#
resource "aws_security_group" "default" {
  count  = var.enabled && var.use_existing_security_groups == false ? 1 : 0
  vpc_id = var.vpc_id
  name   = module.label.id
  tags   = module.label.tags
}

resource "aws_security_group_rule" "egress" {
  count             = var.enabled && var.use_existing_security_groups == false ? 1 : 0
  description       = "Allow all egress traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = join("", aws_security_group.default.*.id)
  type              = "egress"
}

resource "aws_security_group_rule" "ingress_security_groups" {
  count                    = var.enabled && var.use_existing_security_groups == false ? length(var.allowed_security_groups) : 0
  description              = "Allow inbound traffic from existing Security Groups"
  from_port                = var.port
  to_port                  = var.port
  protocol                 = "tcp"
  source_security_group_id = var.allowed_security_groups[count.index]
  security_group_id        = join("", aws_security_group.default.*.id)
  type                     = "ingress"
}

resource "aws_security_group_rule" "ingress_cidr_blocks" {
  count             = var.enabled && var.use_existing_security_groups == false && length(var.allowed_cidr_blocks) > 0 ? 1 : 0
  description       = "Allow inbound traffic from CIDR blocks"
  from_port         = var.port
  to_port           = var.port
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = join("", aws_security_group.default.*.id)
  type              = "ingress"
}

locals {
  elasticache_subnet_group_name = var.elasticache_subnet_group_name != "" ? var.elasticache_subnet_group_name : join("", aws_elasticache_subnet_group.default.*.name)
  # if !cluster, then node_count = replica cluster_size, if cluster then node_count = shard*(replica + 1)
  # Why doing this 'The "count" value depends on resource attributes that cannot be determined until apply'. So pre-calculating
  member_clusters_count = (var.cluster_mode_enabled
    ?
    (var.cluster_mode_num_node_groups * (var.cluster_mode_replicas_per_node_group + 1))
    :
    var.cluster_size
  )
  elasticache_member_clusters = var.enabled ? tolist(aws_elasticache_replication_group.default.0.member_clusters) : []
}

resource "aws_elasticache_subnet_group" "default" {
  count      = var.enabled && var.elasticache_subnet_group_name == "" && length(var.subnets) > 0 ? 1 : 0
  name       = module.label.id
  subnet_ids = var.subnets
}

resource "aws_elasticache_parameter_group" "default" {
  count  = var.enabled ? 1 : 0
  name   = module.label.id
  family = var.family



  dynamic "parameter" {
    for_each = var.cluster_mode_enabled ? concat([{ "name" = "cluster-enabled", "value" = "yes" }], var.parameter) : var.parameter
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }
}

resource "aws_elasticache_replication_group" "default" {
  count = var.enabled ? 1 : 0

  auth_token                    = var.transit_encryption_enabled ? var.auth_token : null
  replication_group_id          = var.replication_group_id == "" ? module.label.id : var.replication_group_id
  replication_group_description = module.label.id
  node_type                     = var.instance_type
  number_cache_clusters         = var.cluster_mode_enabled ? null : var.cluster_size
  port                          = var.port
  parameter_group_name          = join("", aws_elasticache_parameter_group.default.*.name)
  availability_zones            = var.cluster_mode_enabled ? null : slice(var.availability_zones, 0, var.cluster_size)
  automatic_failover_enabled    = var.automatic_failover_enabled
  subnet_group_name             = local.elasticache_subnet_group_name
  security_group_ids            = var.use_existing_security_groups ? var.existing_security_groups : [join("", aws_security_group.default.*.id)]
  maintenance_window            = var.maintenance_window
  notification_topic_arn        = var.notification_topic_arn
  engine_version                = var.engine_version
  at_rest_encryption_enabled    = var.at_rest_encryption_enabled
  transit_encryption_enabled    = var.transit_encryption_enabled
  kms_key_id                    = var.at_rest_encryption_enabled ? var.kms_key_id : null
  snapshot_window               = var.snapshot_window
  snapshot_retention_limit      = var.snapshot_retention_limit
  apply_immediately             = var.apply_immediately

  tags = module.label.tags

  dynamic "cluster_mode" {
    for_each = var.cluster_mode_enabled ? ["true"] : []
    content {
      replicas_per_node_group = var.cluster_mode_replicas_per_node_group
      num_node_groups         = var.cluster_mode_num_node_groups
    }
  }

}

#
# CloudWatch Resources
#
resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  count               = var.enabled ? local.member_clusters_count : 0
  alarm_name          = "${element(local.elasticache_member_clusters, count.index)}-cpu-utilization"
  alarm_description   = "Redis cluster CPU utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods_cache_cpu
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = var.alarm_period_cache_cpu
  statistic           = var.alarm_statistic_cache_cpu

  threshold           = var.alarm_cpu_threshold_percent

  dimensions = {
    CacheClusterId = element(local.elasticache_member_clusters, count.index)
  }

  datapoints_to_alarm       = var.alarm_datapoints_to_alarm_cache_cpu
  alarm_actions             = var.alarm_actions
  insufficient_data_actions = var.insufficient_data_actions
  ok_actions                = var.ok_actions

  treat_missing_data  = var.treat_missing_data

  depends_on          = [aws_elasticache_replication_group.default]

  tags                = module.label.tags
}

resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  count               = var.enabled ? local.member_clusters_count : 0
  alarm_name          = "${element(local.elasticache_member_clusters, count.index)}-freeable-memory"
  alarm_description   = "Redis cluster freeable memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods_cache_memory
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = var.alarm_period_cache_memory
  statistic           = var.alarm_statistic_cache_memory

  threshold           = var.alarm_memory_threshold_bytes

  dimensions = {
    CacheClusterId = element(local.elasticache_member_clusters, count.index)
  }

  datapoints_to_alarm       = var.alarm_datapoints_to_alarm_cache_memory
  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions

  treat_missing_data  = var.treat_missing_data

  depends_on          = [aws_elasticache_replication_group.default]

  tags                = module.label.tags
}

module "dns" {
  source  = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.6.0"
  enabled = var.enabled && var.zone_id != "" ? true : false
  name    = var.dns_subdomain != "" ? var.dns_subdomain : var.name
  ttl     = 60
  zone_id = var.zone_id
  records = var.cluster_mode_enabled ? [join("", aws_elasticache_replication_group.default.*.configuration_endpoint_address)] : [join("", aws_elasticache_replication_group.default.*.primary_endpoint_address)]
}
