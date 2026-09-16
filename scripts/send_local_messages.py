#!/usr/bin/env python3
"""
send_local_messages.py — Send test messages to local SQS emulator
==================================================================
Sends messages to local-sqs in the Kubernetes cluster to demonstrate
KEDA event-driven autoscaling (0 -> 5 pods).
"""

import json
import os
import sys
import time

try:
    import boto3
except ImportError:
    print("Installing boto3 for demo...")
    os.system(f"{sys.executable} -m pip install boto3")
    import boto3

# Connect to local SQS inside cluster or via localhost port-forward
ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:9324")
QUEUE_URL = os.environ.get(
    "SQS_QUEUE_URL",
    f"{ENDPOINT_URL}/000000000000/keda-demo-queue"
)

sqs = boto3.client(
    "sqs",
    region_name="us-east-1",
    endpoint_url=ENDPOINT_URL,
    aws_access_key_id="dummy-key",
    aws_secret_access_key="dummy-secret",
)

def send_messages(count: int = 25):
    print(f"\n🚀 Sending {count} messages to SQS queue: {QUEUE_URL} ...")
    for i in range(1, count + 1):
        body = {
            "event": "order.created",
            "order_id": f"ord-demo-{i:03d}",
            "customer_id": f"cust-{i}",
            "amount": 49.99,
            "timestamp": time.time(),
        }
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(body)
        )
        print(f"  [+] Sent message {i}/{count} (order: ord-demo-{i:03d})")
        time.sleep(0.05)

    print(f"\n✅ All {count} messages sent successfully!")
    print("👉 Watch your other terminal: KEDA will now scale pods from 0 to 5!\n")

if __name__ == "__main__":
    count = 25
    if len(sys.argv) > 1:
        count = int(sys.argv[1])
    send_messages(count)
