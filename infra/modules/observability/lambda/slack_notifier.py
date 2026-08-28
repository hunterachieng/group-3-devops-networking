"""
Forward CloudWatch alarm SNS notifications to Slack via Incoming Webhook.

SNS delivers one or more Records; each Message is JSON from CloudWatch Alarms.
"""
import json
import os
import urllib.request


def _color(state: str) -> str:
    if state == "OK":
        return "good"
    if state == "INSUFFICIENT_DATA":
        return "#439FE0"
    return "danger"


def _title(state: str, alarm_name: str) -> str:
    if state == "OK":
        prefix = ":white_check_mark:"
    elif state == "ALARM":
        prefix = ":rotating_light:"
    else:
        prefix = ":grey_question:"
    return f"{prefix} [{state}] {alarm_name}"


def _build_attachment(message: dict) -> dict:
    state = message.get("NewStateValue", "UNKNOWN")
    alarm_name = message.get("AlarmName", "CloudWatch Alarm")
    description = message.get("AlarmDescription") or message.get("NewStateReason", "")
    region = message.get("Region", "")
    time = message.get("StateChangeTime", "")

    fields = []
    if region:
        fields.append({"title": "Region", "value": region, "short": True})
    if time:
        fields.append({"title": "Time", "value": time, "short": True})

    return {
        "color": _color(state),
        "title": _title(state, alarm_name),
        "text": description,
        "fields": fields,
        "mrkdwn_in": ["text", "fields"],
    }


def _post(webhook_url: str, payload: dict) -> None:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status >= 400:
            body = response.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Slack webhook HTTP {response.status}: {body}")


def handler(event, _context):
    webhook_url = os.environ.get("SLACK_WEBHOOK_URL", "")
    channel = os.environ.get("SLACK_CHANNEL", "#group-3-alerts")

    if not webhook_url:
        raise ValueError("SLACK_WEBHOOK_URL environment variable is not set")

    for record in event.get("Records", []):
        raw = record.get("Sns", {}).get("Message", "{}")
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            message = {"AlarmName": "SNS notification", "NewStateValue": "ALARM", "AlarmDescription": raw}

        payload = {
            "channel": channel,
            "username": "CloudWatch",
            "icon_emoji": ":aws:",
            "attachments": [_build_attachment(message)],
        }
        _post(webhook_url, payload)

    return {"statusCode": 200, "body": "ok"}
