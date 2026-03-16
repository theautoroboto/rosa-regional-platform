"""
Lambda function to send CodePipeline failure notifications to Slack.

This function is triggered by EventBridge when CodePipeline state changes occur.
It supports both Slack Incoming Webhooks and Slack Bot Tokens for sending messages.

Supports:
- Incoming Webhooks: Simple webhook URL (https://hooks.slack.com/...)
- Bot Tokens: OAuth bot tokens (xoxb-...) for multi-channel support
"""

import json
import os
import urllib.request
import urllib.error
from datetime import datetime
from typing import Dict, Any, Optional, List, Tuple

import boto3
from botocore.exceptions import ClientError


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler for processing CodePipeline events and sending Slack notifications.

    Args:
        event: EventBridge event containing CodePipeline state change details
        context: Lambda context object

    Returns:
        Response dictionary with status code and message
    """
    print(f"Received event: {json.dumps(event)}")

    try:
        # Extract event details
        detail = event.get("detail", {})
        detail_type = event.get("detail-type", "")

        # Get Slack credentials from Secrets Manager
        slack_secret = get_slack_secret()

        # Determine if using webhook or bot token
        is_bot_token = slack_secret.startswith("xoxb-")

        # Get notification channels
        channels = get_notification_channels()

        # Format the message based on event type
        message = format_slack_message(detail, detail_type)

        # Send to Slack
        if is_bot_token:
            send_via_bot_token(slack_secret, channels, message)
        else:
            # Webhook URL - send to single channel
            send_via_webhook(slack_secret, message)

        return {
            "statusCode": 200,
            "body": json.dumps("Notification sent successfully")
        }

    except Exception as e:
        print(f"Error processing event: {str(e)}")
        return {
            "statusCode": 500,
            "body": json.dumps(f"Error: {str(e)}")
        }


def get_slack_secret() -> str:
    """
    Retrieve Slack secret (webhook URL or bot token) from AWS Secrets Manager.

    Returns:
        Slack webhook URL or bot token string

    Raises:
        ClientError: If secret cannot be retrieved
    """
    secret_name = os.environ.get("SLACK_WEBHOOK_SECRET")
    region = os.environ.get("AWS_REGION", "us-east-1")

    client = boto3.client("secretsmanager", region_name=region)

    try:
        response = client.get_secret_value(SecretId=secret_name)
        secret = response["SecretString"].strip()
        print(f"Retrieved secret type: {'bot token' if secret.startswith('xoxb-') else 'webhook URL'}")
        return secret
    except ClientError as e:
        print(f"Error retrieving secret {secret_name}: {e}")
        raise


def get_notification_channels() -> List[str]:
    """
    Get list of notification channels from environment variable.

    Returns:
        List of Slack channel names (e.g., ['#pipeline-alerts'])
    """
    channels_str = os.environ.get("NOTIFICATION_CHANNEL", "#pipeline-alerts")
    channels = [ch.strip() for ch in channels_str.split(",")]
    print(f"Notification channels: {channels}")
    return channels


def format_slack_message(detail: Dict[str, Any], detail_type: str) -> Dict[str, Any]:
    """
    Format EventBridge event details into a Slack message payload.

    Args:
        detail: Event detail object from EventBridge
        detail_type: Type of event (pipeline/stage/action execution state change)

    Returns:
        Slack message payload dictionary
    """
    pipeline = detail.get("pipeline", "Unknown")
    state = detail.get("state", "UNKNOWN")
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    account_id = os.environ.get("AWS_ACCOUNT_ID", "unknown")

    # Determine icon and color based on state
    icon, color = get_state_formatting(state)

    # Build base message
    message_text = f"{icon} Pipeline {state}: {pipeline}"

    # Build detailed fields based on event type
    fields = [
        {
            "title": "Pipeline",
            "value": pipeline,
            "short": True
        },
        {
            "title": "Status",
            "value": state,
            "short": True
        }
    ]

    # Add stage information if available
    if "stage" in detail:
        fields.append({
            "title": "Stage",
            "value": detail["stage"],
            "short": True
        })

    # Add action information if available
    if "action" in detail:
        fields.append({
            "title": "Action",
            "value": detail["action"],
            "short": True
        })

    # Add execution ID if available
    if "execution-id" in detail:
        execution_id = detail["execution-id"]
        fields.append({
            "title": "Execution ID",
            "value": execution_id,
            "short": False
        })

    # Add region
    fields.append({
        "title": "Region",
        "value": region,
        "short": True
    })

    # Add timestamp
    timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    fields.append({
        "title": "Time",
        "value": timestamp,
        "short": True
    })

    # Add console links
    pipeline_url = f"https://console.aws.amazon.com/codesuite/codepipeline/pipelines/{pipeline}/view?region={region}"
    logs_url = f"https://console.aws.amazon.com/cloudwatch/home?region={region}#logsV2:log-groups"

    fields.append({
        "title": "Links",
        "value": f"<{pipeline_url}|View Pipeline> | <{logs_url}|View Logs>",
        "short": False
    })

    # Build Slack message payload
    payload = {
        "text": message_text,
        "attachments": [
            {
                "color": color,
                "fields": fields,
                "footer": f"AWS Account: {account_id}",
                "ts": int(datetime.utcnow().timestamp())
            }
        ]
    }

    return payload


def get_state_formatting(state: str) -> Tuple[str, str]:
    """
    Get icon and color for a given pipeline state.

    Args:
        state: Pipeline state (FAILED, STOPPED, SUPERSEDED, etc.)

    Returns:
        Tuple of (icon, color) for Slack message formatting
    """
    state_config = {
        "FAILED": ("❌", "danger"),
        "STOPPED": ("⛔", "warning"),
        "SUPERSEDED": ("⏩", "#808080"),
        "SUCCEEDED": ("✅", "good"),
        "STARTED": ("🚀", "#0066cc"),
        "RESUMED": ("▶️", "#0066cc"),
        "CANCELED": ("🚫", "warning"),
    }

    return state_config.get(state, ("❓", "#808080"))


def send_via_webhook(webhook_url: str, message: Dict[str, Any]) -> None:
    """
    Send notification to Slack via Incoming Webhook.

    Args:
        webhook_url: Slack incoming webhook URL
        message: Message payload dictionary

    Raises:
        urllib.error.HTTPError: If Slack webhook request fails
    """
    headers = {
        "Content-Type": "application/json"
    }

    data = json.dumps(message).encode("utf-8")
    request = urllib.request.Request(webhook_url, data=data, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            if response.status == 200:
                print("Slack notification sent successfully via webhook")
            else:
                print(f"Slack notification failed with status: {response.status}")
                print(f"Response: {response.read().decode('utf-8')}")
    except urllib.error.HTTPError as e:
        print(f"HTTP Error sending Slack notification: {e.code} - {e.reason}")
        print(f"Response body: {e.read().decode('utf-8')}")
        raise
    except urllib.error.URLError as e:
        print(f"URL Error sending Slack notification: {e.reason}")
        raise


def send_via_bot_token(bot_token: str, channels: List[str], message: Dict[str, Any]) -> None:
    """
    Send notification to Slack via Bot Token (chat.postMessage API).

    Supports posting to multiple channels with a single bot token.

    Args:
        bot_token: Slack bot token (xoxb-...)
        channels: List of channel names (e.g., ['#pipeline-alerts', '#critical'])
        message: Message payload dictionary

    Raises:
        urllib.error.HTTPError: If Slack API request fails
    """
    api_url = "https://slack.com/api/chat.postMessage"

    for channel in channels:
        # Prepare payload for chat.postMessage
        payload = {
            "channel": channel,
            "text": message.get("text", "Pipeline notification"),
            "attachments": message.get("attachments", [])
        }

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {bot_token}"
        }

        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(api_url, data=data, headers=headers)

        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                response_data = json.loads(response.read().decode("utf-8"))

                if response_data.get("ok"):
                    print(f"Slack notification sent successfully to {channel} via bot token")
                else:
                    error = response_data.get("error", "unknown error")
                    print(f"Slack API error for channel {channel}: {error}")
                    print(f"Full response: {response_data}")

        except urllib.error.HTTPError as e:
            print(f"HTTP Error sending to {channel}: {e.code} - {e.reason}")
            print(f"Response body: {e.read().decode('utf-8')}")
            # Continue to next channel instead of failing completely
        except urllib.error.URLError as e:
            print(f"URL Error sending to {channel}: {e.reason}")
        except json.JSONDecodeError as e:
            print(f"Error decoding Slack API response for {channel}: {e}")
