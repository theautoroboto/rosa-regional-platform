import boto3
import time
import json
import sys
import os
import subprocess
from botocore.exceptions import ClientError
from datetime import datetime, timezone
from boto3.dynamodb.conditions import Attr

TABLE_NAME = os.environ.get('DYNAMODB_TABLE_NAME', 'AccountPool')
REGION = os.environ.get('AWS_REGION', 'us-east-2')

def run_cloud_nuke(credentials):
    env = os.environ.copy()
    env['AWS_ACCESS_KEY_ID'] = credentials['AccessKeyId']
    env['AWS_SECRET_ACCESS_KEY'] = credentials['SecretAccessKey']
    if credentials.get('SessionToken'):
        env['AWS_SESSION_TOKEN'] = credentials['SessionToken']

    # Calculate absolute path to config file
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(script_dir, '..', 'configs', 'cloud-nuke.yaml')

    cmd = [
        "cloud-nuke", "aws",
        "--region", REGION,
        "--config", config_path,
        "--force"
    ]

    try:
        # Stream output to stderr to allow viewing progress while keeping stdout clean for JSON
        subprocess.run(
            cmd,
            env=env,
            check=True,
            capture_output=False,
            text=True,
            stdout=sys.stderr, # Redirect stdout to stderr
            stderr=sys.stderr  # Redirect stderr to stderr
        )
        return True
    except subprocess.CalledProcessError as e:
        print(f"cloud-nuke failed with exit code {e.returncode}", file=sys.stderr)
        return False
    except FileNotFoundError:
        print(f"cloud-nuke binary not found.", file=sys.stderr)
        return False

def lease_account():
    # Configuration
    # Default timeout reduced to 10s, but configurable via env var
    TIMEOUT_SECONDS = int(os.environ.get('LEASE_TIMEOUT', 10))
    # Retry interval reduced to 2s to allow multiple checks within short timeout
    RETRY_INTERVAL = 2

    print(f"Starting lease_account.py in region {REGION}", file=sys.stderr)
    dynamodb = boto3.resource('dynamodb', region_name=REGION)
    table = dynamodb.Table(TABLE_NAME)

    # Initial check: Ensure the pool is not empty
    try:
        # Scan all items to check if any exist.
        response = table.scan()
        all_items = response.get('Items', [])
        if not all_items:
            print(f"Error: No accounts configured in the AccountPool table '{TABLE_NAME}'.", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"Error scanning table {TABLE_NAME} during initial check: {e}", file=sys.stderr)
        sys.exit(1)

    start_time = time.time()

    while time.time() - start_time < TIMEOUT_SECONDS:
        try:
            # 1. Scan for available accounts
            # Note: For small pool (10 accounts), Scan is efficient enough.
            response = table.scan(
                FilterExpression=Attr('status').eq('AVAILABLE')
            )
            available_accounts = response.get('Items', [])

            for target_account in available_accounts:
                # Check timeout inside loop
                if time.time() - start_time >= TIMEOUT_SECONDS:
                    break

                account_id = target_account['account_id']
                print(f"Attempting to lease account {account_id}...", file=sys.stderr)

                try:
                    # 2. Attempt to lock the account
                    table.update_item(
                        Key={'account_id': account_id},
                        UpdateExpression="SET #s = :in_use, lease_timestamp = :ts",
                        ConditionExpression="#s = :available",
                        ExpressionAttributeNames={'#s': 'status'},
                        ExpressionAttributeValues={
                            ':in_use': 'IN_USE',
                            ':available': 'AVAILABLE',
                            ':ts': datetime.now(timezone.utc).isoformat()
                        }
                    )

                    # Success locking
                    print(f"Successfully locked account {account_id}. Assuming OrganizationAccountAccessRole...", file=sys.stderr)
                    sts = boto3.client('sts', region_name=REGION)
                    try:
                        role_arn = f"arn:aws:iam::{account_id}:role/OrganizationAccountAccessRole"
                        assumed_role_object = sts.assume_role(
                            RoleArn=role_arn,
                            RoleSessionName="LeasedSession",
                            DurationSeconds=3600
                        )

                        credentials = assumed_role_object['Credentials']

                        # 3. Run cloud-nuke
                        print(f"Running cloud-nuke on account {account_id}...", file=sys.stderr)
                        if not run_cloud_nuke(credentials):
                            print(f"Error: cloud-nuke failed for account {account_id}. Marking as DIRTY.", file=sys.stderr)
                            # Mark as DIRTY
                            table.update_item(
                                Key={'account_id': account_id},
                                UpdateExpression="SET #s = :dirty",
                                ExpressionAttributeNames={'#s': 'status'},
                                ExpressionAttributeValues={':dirty': 'DIRTY'}
                            )
                            continue  # Try next available account

                        print(f"cloud-nuke completed for account {account_id}. Returning STS credentials...", file=sys.stderr)

                        # Use the STS credentials from the assumed role
                        # Ensure Expiration is serialized to string
                        expiration = credentials.get('Expiration')
                        if isinstance(expiration, datetime):
                            expiration = expiration.isoformat()

                        result = {
                            "account_id": account_id,
                            "status": "success",
                            "credentials": {
                                "AccessKeyId": credentials['AccessKeyId'],
                                "SecretAccessKey": credentials['SecretAccessKey'],
                                "SessionToken": credentials['SessionToken'],
                                "Expiration": expiration
                            }
                        }

                        print(json.dumps(result))
                        return

                    except Exception as e:
                        print(f"Error leasing account {account_id}: {e}", file=sys.stderr)
                        # If a critical error occurs after locking but before success/continue
                        # we should probably just fail for this run.
                        sys.exit(1)

                except ClientError as e:
                    if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                        # Race condition encountered, try next account in loop
                        pass
                    else:
                        raise e

        except Exception as e:
            print(f"Error scanning/leasing table {TABLE_NAME} in region {REGION}: {e}", file=sys.stderr)

        # Wait before retrying (if loop finished without success)
        time.sleep(RETRY_INTERVAL)

    # Timeout
    print(f"Timeout: No accounts available after {TIMEOUT_SECONDS} seconds.", file=sys.stderr)

    try:
        response = table.scan(
            FilterExpression=Attr('status').eq('IN_USE')
        )
        in_use_accounts = [item['account_id'] for item in response.get('Items', [])]
        if in_use_accounts:
            print(f"Accounts currently IN_USE: {', '.join(in_use_accounts)}", file=sys.stderr)
    except Exception as e:
        print(f"Error scanning for IN_USE accounts: {e}", file=sys.stderr)

    sys.exit(1)

if __name__ == "__main__":
    lease_account()