"""GET /api/products[?category=...&nextToken=...] and GET /api/products/{productId}.

Reads the product catalogue from DynamoDB. Category browsing uses the category-index GSI
(a Query, not a Scan). Results are paginated with an opaque base64 nextToken.
"""
import base64
import json
import logging
import os
import re
from decimal import Decimal

import boto3
from boto3.dynamodb.types import TypeDeserializer

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

PRODUCT_ID_RE = re.compile(r"^[A-Za-z0-9-]{1,40}$")
CATEGORIES = {"pottery", "textiles", "leather", "wood-carvings", "skincare", "jewellery"}
PAGE_SIZE = 24

_client = None
_deser = TypeDeserializer()


def client():
    global _client
    if _client is None:
        _client = boto3.client("dynamodb")
    return _client


def plain(item):
    out = {k: _deser.deserialize(v) for k, v in item.items()}
    for k, v in out.items():
        if isinstance(v, Decimal):
            out[k] = int(v) if v == v.to_integral_value() else float(v)
    return out


def response(status, body, cache_seconds=0):
    headers = {"Content-Type": "application/json"}
    headers["Cache-Control"] = f"public, max-age={cache_seconds}" if cache_seconds else "no-store"
    return {"statusCode": status, "headers": headers, "body": json.dumps(body)}


def encode_token(key):
    return base64.urlsafe_b64encode(json.dumps(key).encode()).decode() if key else None


def decode_token(token):
    try:
        return json.loads(base64.urlsafe_b64decode(token.encode()).decode())
    except Exception as exc:  # noqa: BLE001 - any malformed token is a client error
        raise ValueError("invalid nextToken") from exc


def get_product(product_id):
    if not PRODUCT_ID_RE.match(product_id):
        return response(400, {"message": "invalid productId"})
    resp = client().get_item(TableName=os.environ["PRODUCTS_TABLE"], Key={"productId": {"S": product_id}})
    if "Item" not in resp:
        return response(404, {"message": "product not found"})
    return response(200, plain(resp["Item"]), cache_seconds=300)


def list_products(params):
    table = os.environ["PRODUCTS_TABLE"]
    kwargs = {"TableName": table, "Limit": PAGE_SIZE}
    if params.get("nextToken"):
        kwargs["ExclusiveStartKey"] = decode_token(params["nextToken"])
    category = params.get("category")
    if category:
        if category not in CATEGORIES:
            return response(400, {"message": f"category must be one of {sorted(CATEGORIES)}"})
        resp = client().query(IndexName="category-index",
                              KeyConditionExpression="category = :c",
                              ExpressionAttributeValues={":c": {"S": category}}, **kwargs)
    else:
        resp = client().scan(**kwargs)
    return response(200, {
        "items": [plain(i) for i in resp.get("Items", [])],
        "nextToken": encode_token(resp.get("LastEvaluatedKey")),
    }, cache_seconds=60)


def lambda_handler(event, context):
    try:
        path_params = event.get("pathParameters") or {}
        if path_params.get("productId"):
            return get_product(path_params["productId"])
        return list_products(event.get("queryStringParameters") or {})
    except ValueError as exc:
        return response(400, {"message": str(exc)})
    except Exception:
        LOG.exception("unhandled error")
        return response(500, {"message": "internal error"})
