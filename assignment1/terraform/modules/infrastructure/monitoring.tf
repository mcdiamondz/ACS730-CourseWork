# CloudWatch Alarm for high CPU utilization
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.name}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Triggers when average CPU exceeds 80% for 2 evaluation periods"
  
  dimensions = {
    InstanceId = aws_instance.web[0].id
  }
  
  alarm_actions = []
  ok_actions    = []
  
  tags = local.common_tags
}
