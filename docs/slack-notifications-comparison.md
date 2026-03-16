# Slack Notifications: Choosing the Right Approach

Two methods are available for sending pipeline failure notifications to Slack. This guide helps you choose the right one.

## Quick Comparison

| Feature                   | Incoming Webhooks ⚡                  | Slack App 🚀                                     |
| ------------------------- | ------------------------------------- | ------------------------------------------------ |
| **Setup Time**            | 5 minutes                             | 15 minutes                                       |
| **Slack Installation**    | None (just add webhook to channel)    | Install app to workspace                         |
| **Multi-channel**         | ❌ One webhook per channel            | ✅ One token, unlimited channels                 |
| **Configuration**         | Simple webhook URL                    | OAuth bot token                                  |
| **Token Management**      | Webhook URL (long-lived)              | Bot token (can rotate)                           |
| **Interactive Features**  | ❌ No (text + attachments only)       | ✅ Yes (buttons, modals, etc.)                   |
| **Thread Support**        | ❌ No                                 | ✅ Yes (track executions in threads)             |
| **Private Channels**      | Must have webhook per private channel | Invite bot once, works everywhere                |
| **Best For**              | Testing, single channel, quick setup  | Production, multiple channels, advanced features |
| **Cost**                  | Free                                  | Free                                             |
| **Maintenance**           | Low (webhook rarely changes)          | Medium (may need token rotation)                 |
| **AWS Secrets Manager**   | Store webhook URL                     | Store bot token                                  |
| **Lambda Complexity**     | Simple HTTP POST                      | Slack API calls (handled automatically)          |
| **Workspace Permissions** | Channel-specific                      | Workspace-wide (scoped to bot permissions)       |

## Decision Tree

```mermaid
graph TD
    A[Need pipeline notifications?] -->|Yes| B{Multiple channels?}
    B -->|No, single channel| C[Use Incoming Webhooks]
    B -->|Yes, 2+ channels| D{Need interactive features?}

    D -->|No| E{Production environment?}
    D -->|Yes| F[Use Slack App]

    E -->|Yes| F
    E -->|No, dev/test| C

    C --> G[✅ Setup: 5 min<br/>Docs: slack-notifications-setup.md]
    F --> H[✅ Setup: 15 min<br/>Docs: slack-app-installation.md]
```

## Recommendation by Use Case

### Use Incoming Webhooks If:

- ✅ You have **one notification channel** (e.g., `#pipeline-alerts`)
- ✅ You want **fastest setup** (< 5 minutes)
- ✅ You're in a **development/testing** environment
- ✅ You prefer **simplicity** over features
- ✅ You don't need interactive components

**Guide**: [slack-notifications-setup.md](./slack-notifications-setup.md)

### Use Slack App If:

- ✅ You need **multiple notification channels** (e.g., `#pipeline-alerts`, `#critical`, `#team-platform`)
- ✅ You're deploying to **production**
- ✅ You want **thread support** to track pipeline executions
- ✅ You may need **interactive buttons** (e.g., "Retry Pipeline", "View Logs")
- ✅ You want **centralized token management**
- ✅ You need **fine-grained permissions**

**Guide**: [slack-app-installation.md](./slack-app-installation.md)

## Setup Steps Side-by-Side

### Incoming Webhooks

1. Add webhook to Slack channel (2 min)
2. Store webhook URL in AWS Secrets Manager (1 min)
3. Add Terraform module to pipeline config (2 min)
4. Apply Terraform changes
5. **Done!**

### Slack App

1. Create app from manifest (3 min)
2. Install app to workspace (2 min)
3. Get bot token (1 min)
4. Store token in AWS Secrets Manager (1 min)
5. Add Terraform module to pipeline config (2 min)
6. Invite bot to private channels if needed (1 min)
7. Apply Terraform changes
8. **Done!**

## Example Configurations

### Incoming Webhooks Example

```hcl
# Store webhook in Secrets Manager
# aws secretsmanager create-secret \
#   --name pipeline-notifications/slack-webhook \
#   --secret-string "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

module "pipeline_notifications" {
  source = "../../modules/pipeline-notifications"

  pipeline_name        = aws_codepipeline.central_pipeline.name
  slack_webhook_secret = "pipeline-notifications/slack-webhook"

  # Single channel (defined when webhook was created)
  notification_channels = ["#pipeline-alerts"]  # For documentation only

  tags = {
    Environment = "dev"
  }
}
```

### Slack App Example

```hcl
# Store bot token in Secrets Manager
# aws secretsmanager create-secret \
#   --name pipeline-notifications/slack-bot-token \
#   --secret-string "xoxb-YOUR-BOT-TOKEN"

module "pipeline_notifications" {
  source = "../../modules/pipeline-notifications"

  pipeline_name        = aws_codepipeline.central_pipeline.name
  slack_webhook_secret = "pipeline-notifications/slack-bot-token"

  # Multiple channels supported with bot token
  notification_channels = [
    "#pipeline-alerts",
    "#critical-incidents",
    "#team-platform"
  ]

  tags = {
    Environment = "production"
  }
}
```

## Migration Path

You can start with Incoming Webhooks and migrate to Slack App later:

```mermaid
graph LR
    A[Incoming Webhooks] -->|Growing needs| B[Evaluate]
    B -->|Need multi-channel| C[Migrate to Slack App]
    B -->|Works fine| A
    C -->|Easy migration| D[Both approaches use same Terraform module]
```

### Migration Steps

1. Create Slack App and get bot token
2. Store bot token in new Secrets Manager secret
3. Update Terraform variable: `slack_webhook_secret = "pipeline-notifications/slack-bot-token"`
4. Apply changes
5. Verify notifications work
6. (Optional) Remove old webhook

**Zero downtime**: Both can run simultaneously during migration.

## Feature Comparison

### Incoming Webhooks Features

- ✅ Post messages to a single channel
- ✅ Text formatting (markdown)
- ✅ Attachments with colors and fields
- ✅ Links to AWS Console
- ❌ No buttons or interactive components
- ❌ No threads
- ❌ Cannot post to multiple channels
- ❌ Cannot update/delete messages
- ❌ No user mentions

### Slack App Features

All Incoming Webhooks features **plus**:

- ✅ Post to multiple channels with one token
- ✅ Thread support (track pipeline runs)
- ✅ Interactive buttons (e.g., "Retry", "Approve")
- ✅ Update/delete messages
- ✅ Mention users (`@user`)
- ✅ Rich Block Kit formatting
- ✅ Modal dialogs
- ✅ Slash commands (future)
- ✅ Event subscriptions (future)

## Security Considerations

### Incoming Webhooks

- Webhook URL is permanent (unless regenerated)
- Anyone with URL can post to that channel
- No built-in rotation
- Stored encrypted in AWS Secrets Manager
- Simple to audit (one URL per channel)

### Slack App

- Bot token can be rotated
- Fine-grained OAuth scopes
- Workspace-wide audit logging in Slack
- Token stored encrypted in AWS Secrets Manager
- Can revoke/regenerate tokens easily
- Better for compliance/security requirements

## Cost Comparison

Both are **free** with similar AWS costs:

| Service         | Incoming Webhooks | Slack App   |
| --------------- | ----------------- | ----------- |
| Slack           | Free              | Free        |
| EventBridge     | Free tier         | Free tier   |
| Lambda          | Free tier         | Free tier   |
| Secrets Manager | ~$0.40/month      | ~$0.40/mo   |
| CloudWatch Logs | ~$0.50/GB         | ~$0.50/GB   |
| **Total**       | **< $1/month**    | \*\*< $1/mo |

## Summary

### Start with Incoming Webhooks if you want:

- Fastest setup
- Simplest configuration
- Single notification channel
- Development/testing environment

### Choose Slack App if you need:

- Multiple notification channels
- Production-grade setup
- Future-proof architecture
- Advanced features (threads, buttons)
- Better security controls

---

**Both approaches use the same Terraform module and Lambda function**, so migration is seamless when your needs change.

## Next Steps

1. **Quick start (< 5 min)**: [Incoming Webhooks Setup](./slack-notifications-setup.md)
2. **Production setup (< 15 min)**: [Slack App Installation](./slack-app-installation.md)
3. **Module documentation**: [Terraform Module README](../terraform/modules/pipeline-notifications/README.md)
