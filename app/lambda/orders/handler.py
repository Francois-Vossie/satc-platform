"""POST /api/orders - place an order.

Flow
1. Validate the request body (API Gateway validates too - this is defence in depth).
2. Read unit prices for every SKU from the DynamoDB inventory table.
3. Reserve stock atomically with a DynamoDB transaction: every line uses a
   condition "stock >= quantity", so either all lines are reserved or none are.
4. Write the order and its lines to RDS PostgreSQL inside one SQL transaction
   using parameterised queries only (no string concatenation -> no SQL injection).
5. If the database write fails, release the reserved stock (compensating action)
   and return 500 so the customer can retry.
6. Emit custom CloudWatch metrics (Embedded Metric Format) for the KPI dashboard.

Card data never reaches this function: the browser tokenises it with Stripe
(or the mobile-money provider) so SATC stays in PCI-DSS SAQ-A scope.
"""
import json
import logging
import os
import re
import time
import uuid

import boto3

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

SKU_RE = re.compile(r"^[A-Z0-9-]{3,20}$")
COUNTRY_RE = re.compile(r"^[A-Z]{2}$")
MAX_LINES = 20
MAX_QTY = 50

_dynamodb = None
_secrets = None
_db_conn = None


class ValidationError(Exception):
    pass


class OutOfStock(Exception):
    pass


# ----------------------------------------------------------------------------- clients (lazy, reused across warm invocations)
def dynamodb():
    global _dynamodb
    if _dynamodb is None:
        _dynamodb = boto3.client("dynamodb")
    return _dynamodb


def secrets():
    global _secrets
    if _secrets is None:
        _secrets = boto3.client("secretsmanager")
    return _secrets


def db_connection():
    """Open (or reuse) a TLS connection to RDS using the Secrets Manager credentials."""
    global _db_conn
    if _db_conn is not None and not _db_conn.closed:
        return _db_conn
    import psycopg2  # provided by the Lambda layer

    secret = json.loads(secrets().get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"])
    _db_conn = psycopg2.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ.get("DB_NAME", "satc"),
        user=secret["username"],
        password=secret["password"],
        sslmode="require",
        connect_timeout=5,
    )
    return _db_conn


# ----------------------------------------------------------------------------- helpers
def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body, default=str),
    }


def validate(body):
    if not isinstance(body, dict):
        raise ValidationError("Body must be a JSON object")
    items = body.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_LINES:
        raise ValidationError(f"items must contain 1-{MAX_LINES} lines")
    country = body.get("shippingCountry", "")
    if not isinstance(country, str) or not COUNTRY_RE.match(country):
        raise ValidationError("shippingCountry must be an ISO 3166 alpha-2 code")
    payment = body.get("paymentMethod", "card")
    if payment not in ("card", "mobile_money"):
        raise ValidationError("paymentMethod must be card or mobile_money")
    merged = {}
    for line in items:
        sku = line.get("sku") if isinstance(line, dict) else None
        qty = line.get("quantity") if isinstance(line, dict) else None
        if not isinstance(sku, str) or not SKU_RE.match(sku):
            raise ValidationError("invalid sku")
        if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= MAX_QTY:
            raise ValidationError(f"quantity must be an integer 1-{MAX_QTY}")
        merged[sku] = merged.get(sku, 0) + qty
    return {"items": merged, "shippingCountry": country, "paymentMethod": payment}


def get_prices(skus):
    table = os.environ["INVENTORY_TABLE"]
    resp = dynamodb().batch_get_item(
        RequestItems={table: {"Keys": [{"sku": {"S": s}} for s in skus],
                              "ProjectionExpression": "sku, unitPriceCents, centreId"}}
    )
    found = {i["sku"]["S"]: i for i in resp.get("Responses", {}).get(table, [])}
    missing = [s for s in skus if s not in found]
    if missing:
        raise ValidationError(f"unknown sku(s): {', '.join(sorted(missing))}")
    return {s: (int(found[s]["unitPriceCents"]["N"]), found[s]["centreId"]["S"]) for s in skus}


def _stock_updates(items, sign):
    table = os.environ["INVENTORY_TABLE"]
    ops = []
    for sku, qty in items.items():
        update = {
            "TableName": table,
            "Key": {"sku": {"S": sku}},
            "ExpressionAttributeValues": {":q": {"N": str(qty)}},
        }
        if sign < 0:
            update["UpdateExpression"] = "SET stock = stock - :q"
            update["ConditionExpression"] = "stock >= :q"
        else:
            update["UpdateExpression"] = "SET stock = stock + :q"
        ops.append({"Update": update})
    return ops


def reserve_stock(items):
    try:
        dynamodb().transact_write_items(TransactItems=_stock_updates(items, -1))
    except dynamodb().exceptions.TransactionCanceledException as exc:
        raise OutOfStock("one or more items are out of stock") from exc


def release_stock(items):
    dynamodb().transact_write_items(TransactItems=_stock_updates(items, +1))


def save_order(order_id, customer_sub, order, prices):
    conn = db_connection()
    total = sum(prices[s][0] * q for s, q in order["items"].items())
    with conn:  # commits on success, rolls back on exception
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO orders (order_id, customer_sub, status, payment_method, shipping_country, total_cents) "
                "VALUES (%s, %s, 'pending_payment', %s, %s, %s)",
                (order_id, customer_sub, order["paymentMethod"], order["shippingCountry"], total),
            )
            for sku, qty in order["items"].items():
                price, centre = prices[sku]
                cur.execute(
                    "INSERT INTO order_items (order_id, sku, centre_code, quantity, unit_price_cents) "
                    "VALUES (%s, %s, %s, %s, %s)",
                    (order_id, sku, centre, qty, price),
                )
    return total


def emit_metrics(total_cents, elapsed_ms):
    """CloudWatch Embedded Metric Format - turned into custom metrics without PutMetricData calls."""
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": os.environ.get("METRICS_NAMESPACE", "SATC/lab"),
                "Dimensions": [["Service"]],
                "Metrics": [
                    {"Name": "OrdersPlaced", "Unit": "Count"},
                    {"Name": "OrderValueCents", "Unit": "None"},
                    {"Name": "OrderLatencyMs", "Unit": "Milliseconds"},
                ],
            }],
        },
        "Service": "orders",
        "OrdersPlaced": 1,
        "OrderValueCents": total_cents,
        "OrderLatencyMs": elapsed_ms,
    }))


# ----------------------------------------------------------------------------- entry point
def lambda_handler(event, context):
    started = time.time()
    try:
        claims = event.get("requestContext", {}).get("authorizer", {}).get("claims", {})
        customer_sub = claims.get("sub")
        if not customer_sub:
            return response(401, {"message": "authentication required"})
        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return response(400, {"message": "body is not valid JSON"})
        order = validate(body)
        prices = get_prices(list(order["items"]))
        reserve_stock(order["items"])
        order_id = str(uuid.uuid4())
        try:
            total = save_order(order_id, customer_sub, order, prices)
        except Exception:
            LOG.exception("database write failed - releasing reserved stock")
            release_stock(order["items"])
            raise
        emit_metrics(total, int((time.time() - started) * 1000))
        LOG.info(json.dumps({"event": "order_placed", "orderId": order_id, "lines": len(order["items"])}))
        return response(201, {"orderId": order_id, "status": "pending_payment", "totalCents": total})
    except ValidationError as exc:
        return response(400, {"message": str(exc)})
    except OutOfStock as exc:
        return response(409, {"message": str(exc)})
    except Exception:
        LOG.exception("unhandled error")
        return response(500, {"message": "internal error - please retry"})
