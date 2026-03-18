# Pipeline Notifications Module

Automated Slack notifications for AWS CodePipeline failures using EventBridge and Lambda.

## Architecture

```
CodePipeline (FAILED) → EventBridge Rule → Lambda Function → Slack Webhook
```

## Usage

```hcl
module "pipeline_notifications" {
  source = "../pipeline-notifications"

  slack_webhook_url = var.slack_webhook_url
  name_prefix       = "my-project"
  region            = "us-east-1"
}
```

## Inputs

| Name                | Description                           | Type   | Required |
| ------------------- | ------------------------------------- | ------ | -------- |
| `slack_webhook_url` | Slack webhook URL for notifications   | string | Yes      |
| `name_prefix`       | Prefix for resource names             | string | No       |
| `region`            | AWS Region                            | string | Yes      |

## Slack Webhook Setup

1. Go to [Slack API: Incoming Webhooks](https://api.slack.com/messaging/webhooks)
2. Create or use existing app → Enable "Incoming Webhooks"
3. Add webhook to workspace and select channel
4. Copy webhook URL: `https://hooks.slack.com/services/T00000000/B00000000/XXXX`

## Notification Format

Messages include:

- Pipeline name and failure status
- Execution ID, region, account, timestamp
- Direct link to AWS Console

## Testing

1. Deploy module with webhook URL
2. Trigger a pipeline failure
3. Check Slack for notification
4. View logs: `aws logs tail /aws/lambda/{name_prefix}pipeline-failure-notifier --follow`

## Troubleshooting

- Verify webhook URL is active
- Check Lambda logs for errors
- Ensure pipeline actually failed
- Confirm EventBridge rule is enabled

## Notes

- Monitors pipelines in deployed region and account only
- Currently detects `FAILED` state only
- Webhook URL is marked sensitive and encrypted at rest
