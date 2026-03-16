terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  function_name = "${var.pipeline_name}-notification-handler"
  log_group     = "/aws/lambda/${local.function_name}"
}

# Lambda execution role
resource "aws_iam_role" "lambda_role" {
  name = "${var.pipeline_name}-notification-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# Lambda execution policy
resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-execution-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group}",
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.slack_webhook_secret}*"
      }
    ]
  })
}

# Package Lambda function code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/notify.py"
  output_path = "${path.module}/lambda/notify.zip"
}

# Lambda function
resource "aws_lambda_function" "notification_handler" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = local.function_name
  role             = aws_iam_role.lambda_role.arn
  handler          = "notify.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET = var.slack_webhook_secret
      NOTIFICATION_CHANNEL = join(",", var.notification_channels)
      AWS_ACCOUNT_ID       = data.aws_caller_identity.current.account_id
    }
  }

  tags = var.tags
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = local.log_group
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# EventBridge rule for CodePipeline state changes
resource "aws_cloudwatch_event_rule" "pipeline_state_change" {
  name        = "${var.pipeline_name}-state-change"
  description = "Capture CodePipeline state changes for ${var.pipeline_name}"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      pipeline = [var.pipeline_name]
      state = concat(
        var.notify_on_failed ? ["FAILED"] : [],
        var.notify_on_stopped ? ["STOPPED"] : [],
        var.notify_on_superseded ? ["SUPERSEDED"] : []
      )
    }
  })

  tags = var.tags
}

# EventBridge rule for CodePipeline stage execution state changes
resource "aws_cloudwatch_event_rule" "pipeline_stage_state_change" {
  name        = "${var.pipeline_name}-stage-state-change"
  description = "Capture CodePipeline stage execution state changes for ${var.pipeline_name}"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Stage Execution State Change"]
    detail = {
      pipeline = [var.pipeline_name]
      state = concat(
        var.notify_on_failed ? ["FAILED"] : [],
        var.notify_on_stopped ? ["STOPPED"] : []
      )
    }
  })

  tags = var.tags
}

# EventBridge rule for CodePipeline action execution state changes
resource "aws_cloudwatch_event_rule" "pipeline_action_state_change" {
  name        = "${var.pipeline_name}-action-state-change"
  description = "Capture CodePipeline action execution state changes for ${var.pipeline_name}"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Action Execution State Change"]
    detail = {
      pipeline = [var.pipeline_name]
      state = concat(
        var.notify_on_failed ? ["FAILED"] : [],
        var.notify_on_stopped ? ["STOPPED"] : []
      )
    }
  })

  tags = var.tags
}

# EventBridge target for pipeline state change
resource "aws_cloudwatch_event_target" "pipeline_state_target" {
  rule      = aws_cloudwatch_event_rule.pipeline_state_change.name
  target_id = "SendToLambda"
  arn       = aws_lambda_function.notification_handler.arn
}

# EventBridge target for stage state change
resource "aws_cloudwatch_event_target" "stage_state_target" {
  rule      = aws_cloudwatch_event_rule.pipeline_stage_state_change.name
  target_id = "SendToLambda"
  arn       = aws_lambda_function.notification_handler.arn
}

# EventBridge target for action state change
resource "aws_cloudwatch_event_target" "action_state_target" {
  rule      = aws_cloudwatch_event_rule.pipeline_action_state_change.name
  target_id = "SendToLambda"
  arn       = aws_lambda_function.notification_handler.arn
}

# Lambda permission for EventBridge to invoke the function (pipeline state)
resource "aws_lambda_permission" "allow_eventbridge_pipeline" {
  statement_id  = "AllowExecutionFromEventBridgePipeline"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notification_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_state_change.arn
}

# Lambda permission for EventBridge to invoke the function (stage state)
resource "aws_lambda_permission" "allow_eventbridge_stage" {
  statement_id  = "AllowExecutionFromEventBridgeStage"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notification_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_stage_state_change.arn
}

# Lambda permission for EventBridge to invoke the function (action state)
resource "aws_lambda_permission" "allow_eventbridge_action" {
  statement_id  = "AllowExecutionFromEventBridgeAction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notification_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_action_state_change.arn
}
