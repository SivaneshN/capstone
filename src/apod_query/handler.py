"""
apod-query Lambda

Fronted by API Gateway (HTTP API, payload format 2.0). Handles:
  GET /today          -> today's enriched record (DynamoDB GetItem)
  GET /search?tag=X    -> all archived records whose tags contain X
                          (DynamoDB Scan + FilterExpression, case-insensitive)
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Attr, Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
TAG_INDEX_TABLE_NAME = os.environ.get("TAG_INDEX_TABLE_NAME", "")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
tag_index_table = dynamodb.Table(TAG_INDEX_TABLE_NAME) if TAG_INDEX_TABLE_NAME else None


def _response(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, default=str),
    }


def _get_path_and_query(event):
    """Supports both API Gateway HTTP API v2.0 and v1.0 event shapes."""
    if "rawPath" in event:
        path = event["rawPath"]
        query = event.get("queryStringParameters") or {}
    else:
        path = event.get("path", "/")
        query = event.get("queryStringParameters") or {}
    return path, query


def handle_today():
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    result = table.get_item(Key={"date": today})
    item = result.get("Item")

    if not item:
        return _response(404, {"message": f"No APOD record found yet for {today}"})

    return _response(200, item)


def handle_search(tag):
    if not tag:
        return _response(400, {"message": "Missing required query parameter: tag"})

    tag_lower = tag.strip().lower()

    if tag_index_table:
        # Fast path: O(1) partition lookup on the sparse tag-index table
        # (one item per tag+date, written by apod-fetcher) instead of
        # scanning the whole archive table.
        response = tag_index_table.query(
            KeyConditionExpression=Key("tag").eq(tag_lower)
        )
        dates = [item["date"] for item in response.get("Items", [])]

        items = []
        for date_str in dates:
            record = table.get_item(Key={"date": date_str}).get("Item")
            if record:
                items.append(record)
    else:
        # Fallback path if TAG_INDEX_TABLE_NAME isn't configured: full Scan
        # with a case-insensitive filter. Kept for backward compatibility.
        items = []
        scan_kwargs = {}
        while True:
            response = table.scan(**scan_kwargs)
            for item in response.get("Items", []):
                item_tags = [str(t).lower() for t in item.get("tags", [])]
                if tag_lower in item_tags:
                    items.append(item)
            if "LastEvaluatedKey" not in response:
                break
            scan_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    items.sort(key=lambda i: i.get("date", ""), reverse=True)

    return _response(200, {"tag": tag, "count": len(items), "results": items})


def lambda_handler(event, context):
    path, query = _get_path_and_query(event)
    logger.info("Handling request path=%s query=%s", path, query)

    try:
        if path.rstrip("/") == "/today":
            return handle_today()
        elif path.rstrip("/") == "/search":
            return handle_search(query.get("tag"))
        else:
            return _response(404, {"message": f"Unknown route: {path}"})
    except Exception as exc:  # noqa: BLE001
        logger.exception("Unhandled error processing request")
        return _response(500, {"message": "Internal server error", "error": str(exc)})
