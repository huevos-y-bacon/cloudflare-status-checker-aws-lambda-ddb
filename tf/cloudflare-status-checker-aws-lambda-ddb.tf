# ==========================================
# 1. PROVIDERS & VARIABLES
# ==========================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.45"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS region where your infrastructure is located."
}

variable "sns_topic_arn" {
  type        = string
  description = "The ARN of your existing SNS topic where subscribers are already configured."
}

variable "environment" {
  type        = string
  default     = "env"
  description = "Environment identifier for naming conventions."
}

variable "cloudflare_status_api_url" {
  type        = string
  default     = "https://yh6f0r4529hb.statuspage.io/api/v2/summary.json"
  description = "The Cloudflare status API endpoint to check. See https://www.cloudflarestatus.com/api for details."
}

# ==========================================
# 2. DYNAMODB CACHE TABLE
# ==========================================

resource "aws_dynamodb_table" "alert_cache" {
  name         = "cloudflare-alert-cache-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "AlertId"

  attribute {
    name = "AlertId"
    type = "S"
  }

  ttl {
    attribute_name = "TTL"
    enabled        = true
  }
}

# ==========================================
# 3. IAM ROLE & POLICIES FOR LAMBDA
# ==========================================

resource "aws_iam_role" "lambda_role" {
  name = "cloudflare-status-lambda-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name = "cloudflare-status-lambda-policy-${var.environment}"

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
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = var.sns_topic_arn
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.alert_cache.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# ==========================================
# 4. LAMBDA SOURCE CODE & ARTIFACT
# ==========================================

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"

  source {
    filename = "lambda_function.py"
    content  = <<EOF
import json
import urllib.request
import os
import time
import boto3

def lambda_handler(event, context):
    url = os.environ.get('CLOUDFLARE_STATUS_API_URL', 'https://yh6f0r4529hb.statuspage.io/api/v2/summary.json')
    
    sns_topic_arn = os.environ['SNS_TOPIC_ARN']
    db_table_name = os.environ['DYNAMODB_TABLE']
    environment = os.environ['ENVIRONMENT']
    
    sns_client = boto3.client('sns')
    cw_client = boto3.client('cloudwatch')
    db_client = boto3.client('dynamodb')
    
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'AWS-Lambda-Checker'})
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            
        status_indicator = data.get('status', {}).get('indicator', 'none') 
        status_description = data.get('status', {}).get('description', 'Unknown')
        
        incidents = data.get('incidents', [])
        maintenances = data.get('scheduled_maintenances', [])
        
        print(f"Cloudflare Status Indicator: {status_indicator} - {status_description}")
        
        metric_value = 0 if status_indicator == 'none' else 1
        cw_client.put_metric_data(
            Namespace='Cloudflare/Status',
            MetricData=[
                {
                    'MetricName': 'ActiveIncidents',
                    'Dimensions': [{'Name': 'Environment', 'Value': environment}],
                    'Value': metric_value,
                    'Unit': 'Count'
                },
            ]
        )
        
        if status_indicator != 'none':
            new_alerts_found = False
            
            msg_lines = [
                f"ALERT: Cloudflare Status page indicates a status anomaly.",
                f"Overall Indicator: {status_indicator.upper()}",
                f"Overall Description: {status_description}",
                "\n=========================================",
                "ACTIVE INCIDENTS / ISSUES DETECTED:",
                "========================================="
            ]
            
            if incidents:
                for inc in incidents:
                    inc_id = inc.get('id', 'unknown')
                    updated_at = inc.get('updated_at', str(time.time()))
                    cache_key = f"inc_{inc_id}_{updated_at}"
                    
                    res = db_client.get_item(TableName=db_table_name, Key={'AlertId': {'S': cache_key}})
                    if 'Item' not in res:
                        new_alerts_found = True
                        ttl_val = str(int(time.time()) + (7 * 24 * 3600))
                        db_client.put_item(TableName=db_table_name, Item={'AlertId': {'S': cache_key}, 'TTL': {'N': ttl_val}})
                        
                        msg_lines.append(f"\n[NEW OR UPDATED] Incident: {inc.get('name', 'Unnamed Incident')}")
                        msg_lines.append(f"Status: {inc.get('status', 'Unknown').replace('_', ' ').title()}")
                        msg_lines.append(f"Impact: {inc.get('impact', 'Unknown').upper()}")
                        if inc.get('incident_updates'):
                            msg_lines.append(f"Latest Update: {inc['incident_updates'][0].get('body', 'No text')}")
            else:
                cache_key = f"blanket_{status_indicator}_{status_description.replace(' ', '_')}"
                res = db_client.get_item(TableName=db_table_name, Key={'AlertId': {'S': cache_key}})
                if 'Item' not in res:
                    new_alerts_found = True
                    ttl_val = str(int(time.time()) + (7 * 24 * 3600))
                    db_client.put_item(TableName=db_table_name, Item={'AlertId': {'S': cache_key}, 'TTL': {'N': ttl_val}})
                    msg_lines.append("\nNo named incident block found. Likely a blanket regional routing degradation or global latency anomaly.")
            
            if maintenances:
                msg_lines.extend([
                    "\n=========================================",
                    "ACTIVE SCHEDULED MAINTENANCE:",
                    "========================================="
                ])
                for maint in maintenances:
                    maint_id = maint.get('id', 'unknown')
                    updated_at = maint.get('updated_at', str(time.time()))
                    cache_key = f"maint_{maint_id}_{updated_at}"
                    
                    res = db_client.get_item(TableName=db_table_name, Key={'AlertId': {'S': cache_key}})
                    if 'Item' not in res:
                        new_alerts_found = True
                        ttl_val = str(int(time.time()) + (7 * 24 * 3600))
                        db_client.put_item(TableName=db_table_name, Item={'AlertId': {'S': cache_key}, 'TTL': {'N': ttl_val}})
                        
                        msg_lines.append(f"\n[NEW OR UPDATED] Maintenance Window: {maint.get('name', 'Unnamed Maintenance')}")
                        msg_lines.append(f"Status: {maint.get('status', 'Unknown').replace('_', ' ').title()}")
                        if maint.get('incident_updates'):
                            msg_lines.append(f"Details: {maint['incident_updates'][0].get('body', 'No text')}")

            msg_lines.extend([
                "\n=========================================",
                "View the live status page here: https://www.cloudflarestatus.com/",
                "========================================="
            ])
            
            if new_alerts_found:
                print("New incident or status modification discovered. Dispatched SNS notification.")
                sns_client.publish(
                    TopicArn=sns_topic_arn,
                    Subject=f"[{status_indicator.upper()}] Cloudflare Status Alert",
                    Message="\n".join(msg_lines)
                )
            else:
                print("Active issues detected, but alerts were previously dispatched. Skipping SNS.")
            
        return {
            'statusCode': 200,
            'body': json.dumps(f"Processed status successfully. Status: {status_indicator}")
        }
        
    except Exception as e:
        print(f"Error checking Cloudflare status: {str(e)}")
        raise e
EOF
  }
}

# ==========================================
# 5. LAMBDA FUNCTION CONFIGURATION
# ==========================================

resource "aws_lambda_function" "cloudflare_checker" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "cloudflare-status-checker-${var.environment}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 15

  environment {
    variables = {
      CLOUDFLARE_STATUS_API_URL = var.cloudflare_status_api_url
      SNS_TOPIC_ARN             = var.sns_topic_arn
      DYNAMODB_TABLE            = aws_dynamodb_table.alert_cache.name
      ENVIRONMENT               = var.environment
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.cloudflare_checker.function_name}"
  retention_in_days = 14
}

# ==========================================
# 6. EVENTBRIDGE TRIGGER (CRON SCHEDULE)
# ==========================================

resource "aws_cloudwatch_event_rule" "every_five_minutes" {
  name                = "cloudflare-check-schedule-${var.environment}"
  description         = "Fires every 5 minutes to trigger the Cloudflare status checker"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "check_cloudflare_target" {
  rule      = aws_cloudwatch_event_rule.every_five_minutes.name
  target_id = "TriggerLambda"
  arn       = aws_lambda_function.cloudflare_checker.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cloudflare_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_five_minutes.arn
}

# ==========================================
# 7. OUTPUTS
# ==========================================

output "lambda_function_name" {
  value       = aws_lambda_function.cloudflare_checker.function_name
  description = "The name of the deployed Lambda function."
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.alert_cache.name
  description = "The name of the DynamoDB table used for de-duplication cache."
}

output "eventbridge_rule_name" {
  value       = aws_cloudwatch_event_rule.every_five_minutes.name
  description = "The name of the EventBridge rule managing the cron schedule."
}
