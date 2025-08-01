import json
import boto3
import os
import re
from datetime import datetime

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

RAW_BUCKET = os.environ['RAW_BUCKET_NAME']
TABLE_NAME = os.environ['TABLE_NAME']
table = dynamodb.Table(TABLE_NAME)

# Predefined alert priority mapping
ALERT_PRIORITY_MAP = {
    "Mechanical Problem": "high",
    "Flat Tire": "high",
    "Won't Start": "high",
    "Accident": "high",
    "Heavy Traffic": "medium",
    "Weather Conditions": "medium",
    "Delayed by School": "low",
    "Other": "low",
    "Problem Run": "low"
}

def parse_delay(delay_str):
    if not delay_str:
        return 0

    delay_str = delay_str.lower().strip()
    if 'hour' in delay_str:
        return 60

    match_range = re.match(r"(\\d+)[-–](\\d+)", delay_str)
    match_single = re.match(r"(\\d+)", delay_str)

    if match_range:
        min_d, max_d = map(int, match_range.groups())
        return (min_d + max_d) // 2
    elif match_single:
        return int(match_single.group(1))
    return 0

def validate_payload(data):
    required_fields = ["Busbreakdown ID", "Route Number", "Reason"]
    missing = [f for f in required_fields if f not in data]
    if missing:
        raise ValueError(f"Missing required fields: {', '.join(missing)}")

def handler(event, context):
    try:
        body = json.loads(event['body'])

        # Validate
        validate_payload(body)

        # Save raw payload to S3
        raw_key = f"{datetime.utcnow().isoformat()}.json"
        s3.put_object(
            Bucket=RAW_BUCKET,
            Key=raw_key,
            Body=json.dumps(body),
            ContentType="application/json"
        )

        # Transform data
        reason = body.get("Reason", "Other")
        body["alert_priority"] = ALERT_PRIORITY_MAP.get(reason, "low")
        body["average_delay_minutes"] = parse_delay(body.get("How Long Delayed", ""))

        # Put transformed data into DynamoDB
        table.put_item(Item={
            "RouteNumber": body["Route Number"],
            "OccurredOn": body.get("Occurred On", datetime.utcnow().isoformat()),
            **body
        })

        return {
            "statusCode": 200,
            "body": json.dumps({"message": "Processed successfully"})
        }

    except Exception as e:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": str(e)})
        }
