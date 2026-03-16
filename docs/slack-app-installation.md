# Slack App Installation for Pipeline Notifications

This guide shows how to install a Slack App for pipeline notifications using the app manifest. This is an alternative to the Incoming Webhooks approach.

## Slack App vs Incoming Webhooks

| Feature               | Slack App (This Guide)           | Incoming Webhooks           |
| --------------------- | -------------------------------- | --------------------------- |
| Installation          | Create & install app             | Just add webhook to channel |
| Token Management      | Bot token (OAuth)                | Webhook URL                 |
| Multi-channel support | ✅ Easy (one token, any channel) | ⚠️ One webhook per channel  |
| Workspace-wide        | ✅ Yes                           | ❌ No (per channel)         |
| Modern Slack features | ✅ Yes (interactive, etc.)       | ❌ Limited                  |
| Setup complexity      | Medium                           | Simple                      |
| Best for              | Production, multi-channel        | Quick setup, single channel |

**Recommendation**: Use Slack App for production deployments with multiple channels. Use Incoming Webhooks for quick testing or single-channel setups.

## Step 1: Create the Slack App

### 1.1 Go to Slack App Management

1. Visit [https://api.slack.com/apps](https://api.slack.com/apps)
2. Click **Create New App**
3. Select **From an app manifest**
4. Choose your workspace
5. Click **Next**

### 1.2 Paste the Manifest

Select **YAML** tab and paste the contents of [`slack-app-manifest.yaml`](./slack-app-manifest.yaml):

```yaml
display_information:
  name: Pipeline Notifications
  description: Sends AWS CodePipeline failure notifications to Slack channels
  background_color: "#4A154B"

features:
  bot_user:
    display_name: Pipeline Notifications
    always_online: true

oauth_config:
  scopes:
    bot:
      - incoming-webhook
      - chat:write
      - chat:write.public

settings:
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

Click **Next** → **Create**

### 1.3 Install the App to Your Workspace

1. On the app settings page, click **Install to Workspace**
2. Review the permissions:
   - Send messages as @Pipeline Notifications
   - Post to specific channels
   - Post to public channels without joining
3. Click **Allow**

## Step 2: Get the Bot Token

1. After installation, go to **OAuth & Permissions** in the sidebar
2. Copy the **Bot User OAuth Token** (starts with `xoxb-`)
3. **Important**: This token provides access to your workspace - keep it secure!

## Step 3: Store Token in AWS Secrets Manager

Instead of storing a webhook URL, store the bot token:

```bash
export AWS_PROFILE=central-account

# Store the bot token
aws secretsmanager create-secret \
  --name pipeline-notifications/slack-bot-token \
  --description "Slack bot token for pipeline failure notifications" \
  --secret-string "xoxb-YOUR-BOT-TOKEN-HERE" \
  --region us-east-1

# Verify it was stored
aws secretsmanager get-secret-value \
  --secret-id pipeline-notifications/slack-bot-token \
  --region us-east-1 \
  --query SecretString --output text
```

## Step 4: Update Lambda Function

The Lambda function needs to support both webhook URLs and bot tokens. Update the module configuration:

```hcl
module "pipeline_notifications" {
  source = "../../modules/pipeline-notifications"

  pipeline_name        = aws_codepipeline.central_pipeline.name
  slack_webhook_secret = "pipeline-notifications/slack-bot-token"  # Bot token instead of webhook
  notification_channel = "#pipeline-alerts"  # Channel to post to

  # Optional: specify if using bot token vs webhook URL
  use_bot_token = true

  tags = {
    Environment = var.target_environment
    Region      = var.target_region
  }
}
```

## Step 5: Update Lambda Code for Bot Token Support

The Lambda function automatically detects if the secret is a bot token (starts with `xoxb-`) or webhook URL (starts with `https://hooks.slack.com`).

For bot tokens, it uses the Slack Web API:

- Endpoint: `https://slack.com/api/chat.postMessage`
- Authentication: `Authorization: Bearer xoxb-...`
- Channel specification: `channel: "#pipeline-alerts"`

## Step 6: Invite Bot to Channels (Optional)

For private channels, invite the bot:

```
/invite @Pipeline Notifications
```

For public channels, the bot can post without joining (using `chat:write.public` scope).

## Testing

### Test with a curl command

```bash
BOT_TOKEN="xoxb-YOUR-BOT-TOKEN"
CHANNEL="#pipeline-alerts"

curl -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"channel\": \"$CHANNEL\",
    \"text\": \"Test notification from Pipeline Notifications app\",
    \"attachments\": [{
      \"color\": \"good\",
      \"text\": \"This is a test message\"
    }]
  }"
```

Expected response:

```json
{
  "ok": true,
  "channel": "C01234567",
  "ts": "1234567890.123456",
  "message": { ... }
}
```

## Advanced Features

### Multiple Channels

With a bot token, you can post to multiple channels without multiple webhooks:

```hcl
module "pipeline_notifications" {
  source = "../../modules/pipeline-notifications"

  pipeline_name         = aws_codepipeline.central_pipeline.name
  slack_webhook_secret  = "pipeline-notifications/slack-bot-token"
  notification_channels = ["#pipeline-alerts", "#critical-incidents", "#platform-team"]

  use_bot_token = true
}
```

The Lambda function will post to all specified channels.

### Rich Message Formatting

Bot tokens support Block Kit for rich interactive messages:

```python
# In Lambda function
blocks = [
    {
        "type": "header",
        "text": {
            "type": "plain_text",
            "text": "🚨 Pipeline Failed"
        }
    },
    {
        "type": "section",
        "fields": [
            {"type": "mrkdwn", "text": f"*Pipeline:*\n{pipeline_name}"},
            {"type": "mrkdwn", "text": f"*Status:*\n{state}"}
        ]
    },
    {
        "type": "actions",
        "elements": [
            {
                "type": "button",
                "text": {"type": "plain_text", "text": "View Pipeline"},
                "url": pipeline_url
            }
        ]
    }
]
```

### Thread Replies

Track pipeline executions in threads:

```python
# Post initial message
response = post_message(channel, text, thread_ts=None)
thread_ts = response['ts']

# Post updates to the same thread
post_message(channel, "Stage Deploy failed", thread_ts=thread_ts)
post_message(channel, "Pipeline execution completed", thread_ts=thread_ts)
```

## Security Considerations

### Token Rotation

Slack bot tokens don't expire, but you should rotate them periodically:

1. Go to app settings → **OAuth & Permissions**
2. Click **Regenerate Token**
3. Update AWS Secrets Manager with new token
4. Lambda will use new token on next invocation

### Enable Secrets Manager Rotation

```bash
aws secretsmanager rotate-secret \
  --secret-id pipeline-notifications/slack-bot-token \
  --rotation-lambda-arn arn:aws:lambda:REGION:ACCOUNT:function:rotate-slack-token
```

### Least Privilege

The app manifest only requests necessary scopes:

- `chat:write` - Post messages to channels
- `chat:write.public` - Post to public channels without joining
- `incoming-webhook` - Backwards compatibility

### Audit Logging

Monitor token usage in Slack:

1. Go to workspace settings → **Logs**
2. Filter by app name: "Pipeline Notifications"
3. Review API calls and message posts

## Troubleshooting

### "channel_not_found" error

**Solution**: Invite the bot to the channel or use a public channel

```
/invite @Pipeline Notifications
```

### "not_authed" or "invalid_auth" error

**Solution**: Check that bot token is correct and not expired

```bash
curl -X POST https://slack.com/api/auth.test \
  -H "Authorization: Bearer $BOT_TOKEN"
```

### Messages not appearing

**Solution**: Verify bot has correct scopes

1. Go to app settings → **OAuth & Permissions**
2. Ensure `chat:write` and `chat:write.public` are listed under **Bot Token Scopes**
3. If missing, add them and reinstall the app

## Comparison with Incoming Webhooks

### When to Use Slack App

- ✅ Multiple channels
- ✅ Production environment
- ✅ Need interactive features (buttons, menus)
- ✅ Want centralized token management
- ✅ Thread support for tracking executions

### When to Use Incoming Webhooks

- ✅ Quick setup (5 minutes)
- ✅ Single channel only
- ✅ Testing/development
- ✅ No interactive features needed
- ✅ Simpler architecture

## Migration from Incoming Webhooks

If you're already using Incoming Webhooks and want to migrate:

1. Create and install Slack app (Steps 1-2)
2. Store bot token in Secrets Manager
3. Update Terraform module configuration:

   ```hcl
   # Old (Incoming Webhook)
   slack_webhook_secret = "pipeline-notifications/slack-webhook"

   # New (Bot Token)
   slack_webhook_secret = "pipeline-notifications/slack-bot-token"
   use_bot_token        = true
   ```

4. Apply Terraform changes
5. Test notifications
6. Remove old webhook from Slack (optional)

## Further Reading

- [Slack App Manifests](https://api.slack.com/reference/manifests)
- [Slack Bot Users](https://api.slack.com/bot-users)
- [Slack Web API - chat.postMessage](https://api.slack.com/methods/chat.postMessage)
- [Block Kit Builder](https://app.slack.com/block-kit-builder)
