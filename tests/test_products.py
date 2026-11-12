import json
from unittest import mock

import pytest

from conftest import load

products = load("products_handler", "app/lambda/products/handler.py")

ITEM = {"productId": {"S": "P-100"}, "name": {"S": "Kalahari clay bowl"}, "category": {"S": "pottery"},
        "priceCents": {"N": "4500"}, "rating": {"N": "4.5"}}


@pytest.fixture
def ddb():
    client = mock.MagicMock()
    with mock.patch.object(products, "_client", client):
        yield client


def test_get_single_product(ddb):
    ddb.get_item.return_value = {"Item": ITEM}
    resp = products.lambda_handler({"pathParameters": {"productId": "P-100"}}, None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["priceCents"] == 4500 and body["rating"] == 4.5
    assert "max-age=300" in resp["headers"]["Cache-Control"]


def test_missing_product_is_404(ddb):
    ddb.get_item.return_value = {}
    assert products.lambda_handler({"pathParameters": {"productId": "P-999"}}, None)["statusCode"] == 404


def test_injection_style_id_rejected(ddb):
    resp = products.lambda_handler({"pathParameters": {"productId": "1 OR 1=1"}}, None)
    assert resp["statusCode"] == 400
    ddb.get_item.assert_not_called()


def test_category_uses_gsi_query_not_scan(ddb):
    ddb.query.return_value = {"Items": [ITEM]}
    resp = products.lambda_handler({"queryStringParameters": {"category": "pottery"}}, None)
    assert resp["statusCode"] == 200
    assert ddb.query.call_args.kwargs["IndexName"] == "category-index"
    ddb.scan.assert_not_called()


def test_unknown_category_rejected(ddb):
    resp = products.lambda_handler({"queryStringParameters": {"category": "weapons"}}, None)
    assert resp["statusCode"] == 400


def test_pagination_round_trip(ddb):
    ddb.scan.return_value = {"Items": [ITEM], "LastEvaluatedKey": {"productId": {"S": "P-100"}}}
    first = json.loads(products.lambda_handler({}, None)["body"])
    assert first["nextToken"]
    products.lambda_handler({"queryStringParameters": {"nextToken": first["nextToken"]}}, None)
    assert ddb.scan.call_args.kwargs["ExclusiveStartKey"] == {"productId": {"S": "P-100"}}


def test_bad_token_rejected(ddb):
    resp = products.lambda_handler({"queryStringParameters": {"nextToken": "%%%"}}, None)
    assert resp["statusCode"] == 400
