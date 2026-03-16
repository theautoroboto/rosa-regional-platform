output "lambda_function_arn" {
  description = "ARN of the Lambda function handling notifications"
  value       = aws_lambda_function.notification_handler.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function handling notifications"
  value       = aws_lambda_function.notification_handler.function_name
}

output "eventbridge_rule_arns" {
  description = "ARNs of the EventBridge rules monitoring pipeline state"
  value = {
    pipeline = aws_cloudwatch_event_rule.pipeline_state_change.arn
    stage    = aws_cloudwatch_event_rule.pipeline_stage_state_change.arn
    action   = aws_cloudwatch_event_rule.pipeline_action_state_change.arn
  }
}

output "log_group_name" {
  description = "CloudWatch Log Group name for Lambda logs"
  value       = aws_cloudwatch_log_group.lambda_logs.name
}
