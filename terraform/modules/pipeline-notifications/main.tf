data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Use name_prefix if provided, otherwise empty string
  resource_prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""
}

# Lambda function to format and send Slack notifications for CodePipeline failures
data "archive_file" "slack_notifier" {
  type        = "zip"
  output_path = "${path.module}/slack_notifier.zip"

  source {
    content  = <<-EOF
      import json
      import urllib3
      import os

      http = urllib3.PoolManager()

      def lambda_handler(event, context):
          webhook_url = os.environ['SLACK_WEBHOOK_URL']

          # Extract pipeline failure details from EventBridge event
          detail = event.get('detail', {})
          pipeline_name = detail.get('pipeline', 'Unknown')
          execution_id = detail.get('execution-id', 'Unknown')
          state = detail.get('state', 'Unknown')
          region = event.get('region', 'Unknown')
          account = event.get('account', 'Unknown')
          time = event.get('time', 'Unknown')

          # Build console URL for the failed pipeline
          console_url = f"https://console.aws.amazon.com/codesuite/codepipeline/pipelines/{pipeline_name}/view?region={region}"

          # Build Slack message with rich formatting
          slack_message = {
              "text": f":x: Pipeline Failure: {pipeline_name}",
              "blocks": [
                  {
                      "type": "header",
                      "text": {
                          "type": "plain_text",
                          "text": f":x: Pipeline Failed: {pipeline_name}"
                      }
                  },
                  {
                      "type": "section",
                      "fields": [
                          {
                              "type": "mrkdwn",
                              "text": f"*Pipeline:*\n{pipeline_name}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*State:*\n{state}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Execution ID:*\n{execution_id}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Region:*\n{region}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Account:*\n{account}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Time:*\n{time}"
                          }
                      ]
                  },
                  {
                      "type": "actions",
                      "elements": [
                          {
                              "type": "button",
                              "text": {
                                  "type": "plain_text",
                                  "text": "View Pipeline in AWS Console"
                              },
                              "url": console_url,
                              "style": "danger"
                          }
                      ]
                  }
              ]
          }

          # Send to Slack
          encoded_data = json.dumps(slack_message).encode('utf-8')
          response = http.request(
              'POST',
              webhook_url,
              body=encoded_data,
              headers={'Content-Type': 'application/json'}
          )

          return {
              'statusCode': response.status,
              'body': json.dumps('Notification sent to Slack')
          }
    EOF
    filename = "lambda_function.py"
  }
}

# IAM role for Lambda function
resource "aws_iam_role" "slack_notifier" {
  name = "${local.resource_prefix}slack-notifier-role"

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
}

# IAM policy for Lambda CloudWatch Logs
resource "aws_iam_role_policy" "slack_notifier_logs" {
  role = aws_iam_role.slack_notifier.name

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
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.resource_prefix}pipeline-failure-notifier:*"
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "slack_notifier" {
  filename         = data.archive_file.slack_notifier.output_path
  function_name    = "${local.resource_prefix}pipeline-failure-notifier"
  role            = aws_iam_role.slack_notifier.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.slack_notifier.output_base64sha256
  runtime         = "python3.12"
  timeout         = 30

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "slack_notifier" {
  name              = "/aws/lambda/${aws_lambda_function.slack_notifier.function_name}"
  retention_in_days = 7
}

# EventBridge rule to detect CodePipeline failures
resource "aws_cloudwatch_event_rule" "pipeline_failure" {
  name        = "${local.resource_prefix}pipeline-failure-detection"
  description = "Detects when any CodePipeline execution fails"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      state = ["FAILED"]
    }
  })
}

# EventBridge target to invoke Lambda
resource "aws_cloudwatch_event_target" "slack_notifier" {
  rule      = aws_cloudwatch_event_rule.pipeline_failure.name
  target_id = "SendToSlackLambda"
  arn       = aws_lambda_function.slack_notifier.arn
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_failure.arn
}
