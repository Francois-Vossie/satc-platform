import json
from unittest import mock

import pytest

from conftest import load

orders = load("orders_handler", "app/lambda/orders/handler.py")


class TxCancelled(Exception):
    pass


def event(body, sub="user-123"):
    ctx = {"authorizer": {"claims": {"sub": sub}}} if sub else {}
    return {"body": json.dumps(body) if not isinstance(body, str) else body, "requestContext": ctx}


VALID = {"items": [{"sku": "POT-001", "quantity": 2}, {"sku": "TEX-010", "quantity": 1}],
         "shippingCountry": "DE", "paymentMethod": "card"}


@pytest.fixture
def ddb():
    client = mock.MagicMock()
    client.exceptions.TransactionCanceledException = TxCancelled
    client.batch_get_item.return_value = {"Responses": {"satc-test-inventory": [
        {"sku": {"S": "POT-001"}, "unitPriceCents": {"N": "4500"}, "centreId": {"S": "BW-GAB"}},
        {"sku": {"S": "TEX-010"}, "unitPriceCents": {"N": "12000"}, "centreId": {"S": "ZA-JHB"}},
    ]}}
    with mock.patch.object(orders, "_dynamodb", client):
        yield client


@pytest.fixture
def db():
    conn = mock.MagicMock()
    conn.closed = 0
    with mock.patch.object(orders, "db_connection", return_value=conn):
        yield conn


def test_valid_order_is_created(ddb, db, capsys):
    resp = orders.lambda_handler(event(VALID), None)
    assert resp["statusCode"] == 201
    body = json.loads(resp["body"])
    assert body["totalCents"] == 2 * 4500 + 12000
    assert body["status"] == "pending_payment"
    # stock reserved with a conditional transaction
    tx = ddb.transact_write_items.call_args.kwargs["TransactItems"]
    assert all(op["Update"]["ConditionExpression"] == "stock >= :q" for op in tx)
    # order header + 2 lines written with parameterised SQL
    cur = db.cursor.return_value.__enter__.return_value
    assert cur.execute.call_count == 3
    for call in cur.execute.call_args_list:
        sql, params = call.args
        assert "%s" in sql and isinstance(params, tuple)
    # EMF metric emitted
    assert '"OrdersPlaced": 1' in capsys.readouterr().out


def test_duplicate_skus_are_merged(ddb, db):
    body = dict(VALID, items=[{"sku": "POT-001", "quantity": 1}, {"sku": "POT-001", "quantity": 3}])
    ddb.batch_get_item.return_value["Responses"]["satc-test-inventory"].pop()
    resp = orders.lambda_handler(event(body), None)
    assert resp["statusCode"] == 201
    tx = ddb.transact_write_items.call_args.kwargs["TransactItems"]
    assert len(tx) == 1 and tx[0]["Update"]["ExpressionAttributeValues"][":q"]["N"] == "4"


def test_requires_authentication(ddb, db):
    assert orders.lambda_handler(event(VALID, sub=None), None)["statusCode"] == 401


@pytest.mark.parametrize("bad", [
    {"items": [], "shippingCountry": "ZA"},
    {"items": [{"sku": "POT-001", "quantity": 0}], "shippingCountry": "ZA"},
    {"items": [{"sku": "POT-001", "quantity": 51}], "shippingCountry": "ZA"},
    {"items": [{"sku": "POT-001", "quantity": True}], "shippingCountry": "ZA"},
    {"items": [{"sku": "x' OR '1'='1", "quantity": 1}], "shippingCountry": "ZA"},
    {"items": [{"sku": "POT-001", "quantity": 1}], "shippingCountry": "South Africa"},
    {"items": [{"sku": "POT-001", "quantity": 1}], "shippingCountry": "ZA", "paymentMethod": "cash"},
])
def test_invalid_input_rejected_before_any_aws_call(ddb, db, bad):
    resp = orders.lambda_handler(event(bad), None)
    assert resp["statusCode"] == 400
    ddb.transact_write_items.assert_not_called()


def test_malformed_json(ddb, db):
    assert orders.lambda_handler(event("{not json"), None)["statusCode"] == 400


def test_unknown_sku(ddb, db):
    body = dict(VALID, items=[{"sku": "NOPE-999", "quantity": 1}])
    resp = orders.lambda_handler(event(body), None)
    assert resp["statusCode"] == 400 and "unknown sku" in resp["body"]


def test_out_of_stock_returns_409(ddb, db):
    ddb.transact_write_items.side_effect = TxCancelled()
    resp = orders.lambda_handler(event(VALID), None)
    assert resp["statusCode"] == 409
    db.cursor.assert_not_called()


def test_db_failure_releases_stock(ddb, db):
    db.cursor.return_value.__enter__.return_value.execute.side_effect = RuntimeError("db down")
    resp = orders.lambda_handler(event(VALID), None)
    assert resp["statusCode"] == 500
    assert ddb.transact_write_items.call_count == 2          # reserve, then release
    release = ddb.transact_write_items.call_args_list[1].kwargs["TransactItems"]
    assert all("stock + :q" in op["Update"]["UpdateExpression"] for op in release)
