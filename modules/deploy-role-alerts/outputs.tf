output "sns_topic_arn" {
  description = "ARN of this account's deploy-role-alerts SNS topic, in case another resource needs to publish to it too."
  value       = aws_sns_topic.deploy_role_alerts.arn
}
