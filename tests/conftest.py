import importlib.util
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ.setdefault("AWS_DEFAULT_REGION", "af-south-1")
os.environ.setdefault("PRODUCTS_TABLE", "satc-test-products")
os.environ.setdefault("INVENTORY_TABLE", "satc-test-inventory")
os.environ.setdefault("DB_SECRET_ARN", "arn:aws:secretsmanager:af-south-1:111111111111:secret:rds!db-test")
os.environ.setdefault("DB_HOST", "db.example.internal")
sys.path.insert(0, str(ROOT / "app" / "web"))


def load(name, rel):
    """Import a Lambda handler by path (each function has its own handler.py)."""
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
