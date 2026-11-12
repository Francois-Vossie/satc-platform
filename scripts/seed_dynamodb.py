"""Load sample products and stock levels into DynamoDB.

Usage: python3 scripts/seed_dynamodb.py --env lab [--region af-south-1]
"""
import argparse

import boto3

CENTRES = ["BW-GAB", "BW-MAU", "ZA-JHB", "ZA-CPT", "ZW-BUL", "ZW-HRE", "NA-WDH", "NA-SWP"]
PRODUCTS = [
    ("POT-001", "Kalahari clay bowl", "pottery", "BW-GAB", 4500),
    ("POT-002", "Okavango water jar", "pottery", "BW-GAB", 6800),
    ("TEX-010", "Hand-woven Ndebele throw", "textiles", "ZA-JHB", 12000),
    ("TEX-011", "Shweshwe cushion cover", "textiles", "ZA-JHB", 3500),
    ("LEA-020", "Kudu leather satchel", "leather", "NA-WDH", 15500),
    ("LEA-021", "Hand-stitched wallet", "leather", "BW-MAU", 4200),
    ("WOD-030", "Mukwa wood elephant", "wood-carvings", "ZW-BUL", 8900),
    ("SKN-040", "Marula oil body butter", "skincare", "ZA-CPT", 2200),
    ("SKN-041", "Rooibos face balm", "skincare", "ZA-CPT", 1900),
    ("JEW-050", "Recycled brass bangle set", "jewellery", "ZW-HRE", 2900),
    ("JEW-051", "Ostrich-shell bead necklace", "jewellery", "NA-SWP", 5400),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="satc")
    ap.add_argument("--env", default="lab")
    ap.add_argument("--region", default=None)
    a = ap.parse_args()
    ddb = boto3.resource("dynamodb", region_name=a.region)
    products = ddb.Table(f"{a.project}-{a.env}-products")
    inventory = ddb.Table(f"{a.project}-{a.env}-inventory")
    with products.batch_writer() as pw, inventory.batch_writer() as iw:
        for sku, name, cat, centre, price in PRODUCTS:
            pw.put_item(Item={"productId": sku, "name": name, "category": cat, "centreId": centre,
                              "priceCents": price, "currency": "USD", "imageKey": f"products/{sku}.jpg"})
            iw.put_item(Item={"sku": sku, "centreId": centre, "stock": 100, "reorderLevel": 10,
                              "unitPriceCents": price})
    print(f"Seeded {len(PRODUCTS)} products and stock records")


if __name__ == "__main__":
    main()
