import json


def handler(event, context):
    """Stub handler — replace with real ingestion code via CI/CD."""
    print(json.dumps({"message": "stub handler invoked", "event": event}))
    return {"statusCode": 200}
