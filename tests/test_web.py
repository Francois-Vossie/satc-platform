from unittest import mock

import app as web


class FakeCache(dict):
    def get(self, key):
        return super().get(key)

    def setex(self, key, ttl, value):
        self[key] = value


def client(table=None, cache=None):
    return web.create_app(table=table or mock.MagicMock(), cache=cache).test_client()


def test_health_for_alb_and_codedeploy():
    resp = client().get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_security_headers_present():
    resp = client().get("/")
    assert resp.headers["X-Frame-Options"] == "DENY"
    assert resp.headers["X-Content-Type-Options"] == "nosniff"


def test_catalogue_cached_in_redis():
    table = mock.MagicMock()
    table.scan.return_value = {"Items": [{"productId": "P-1"}]}
    cache = FakeCache()
    c = client(table, cache)
    assert c.get("/app/products").headers["X-Cache"] == "MISS"
    assert c.get("/app/products").headers["X-Cache"] == "HIT"
    assert table.scan.call_count == 1
