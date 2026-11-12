"""SATC web application on EC2 (behind the ALB, deployed by CodeDeploy).

Serves the staff portal pages under /app/*, a /health endpoint for ALB and CodeDeploy
health checks, and reads the catalogue from DynamoDB. It caches
the first catalogue page in Redis for 300 s when REDIS_HOST is set. Instances keep no
state, so any instance in the Auto Scaling group can serve any request.
"""
import os
import socket

from flask import Flask, jsonify

VERSION = os.environ.get("APP_VERSION", "1.1.0")


def create_app(table=None, cache=None):
    app = Flask(__name__)

    def products_table():
        nonlocal table
        if table is None:
            import boto3
            table = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "af-south-1")) \
                .Table(os.environ.get("PRODUCTS_TABLE", "satc-lab-products"))
        return table

    @app.get("/health")
    def health():
        return jsonify(status="ok", version=VERSION, host=socket.gethostname())

    @app.get("/")
    @app.get("/app/")
    def home():
        return (f"<h1>Savanna Artisan Trading Cooperative</h1>"
                f"<p>Staff portal v{VERSION} served by {socket.gethostname()}</p>")

    @app.get("/app/products")
    def products():
        key = "catalogue:first-page"
        if cache is not None:
            hit = cache.get(key)
            if hit is not None:
                return app.response_class(hit, mimetype="application/json", headers={"X-Cache": "HIT"})
        items = products_table().scan(Limit=50).get("Items", [])
        body = jsonify(items=items).get_data(as_text=True)
        if cache is not None:
            cache.setex(key, 300, body)  # catalogue cache: 5 minutes
        return app.response_class(body, mimetype="application/json", headers={"X-Cache": "MISS"})

    @app.after_request
    def security_headers(resp):
        resp.headers.setdefault("X-Content-Type-Options", "nosniff")
        resp.headers.setdefault("X-Frame-Options", "DENY")
        resp.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        return resp

    return app


def _redis_or_none():
    host = os.environ.get("REDIS_HOST")
    if not host:
        return None
    import redis  # optional dependency
    return redis.Redis(host=host, port=6379, ssl=True, socket_timeout=0.5)


app = create_app(cache=_redis_or_none())
