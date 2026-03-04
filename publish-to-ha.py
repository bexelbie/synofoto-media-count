#!/usr/bin/env python3
# ABOUTME: Publishes Synology Photos media counts for all users to Home Assistant
# ABOUTME: via MQTT auto-discovery using the HA REST API. No extra binaries needed.

import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error

VERBOSE = False


def log(msg):
    """Print only when --verbose is set."""
    if VERBOSE:
        print(msg)

# ── Configuration ─────────────────────────────────────────────────────────────
# Edit these values for your environment.
HA_URL = "http://homeassistant.local:8123"
HA_TOKEN = "YOUR_LONG_LIVED_ACCESS_TOKEN_HERE"

# Path to count-media.sh (same directory by default)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
COUNT_SCRIPT = os.path.join(SCRIPT_DIR, "count-media.sh")

# Extra flags passed through to count-media.sh (e.g. ["--no-sudo", "--db-name", "mydb"])
COUNT_EXTRA_ARGS = []
# ──────────────────────────────────────────────────────────────────────────────

DISCOVERY_PREFIX = "homeassistant"
STATE_TOPIC_PREFIX = "synofoto"

METRICS = {
    "photos": "Non-live Photos",
    "live_photos": "Live Photos",
    "videos": "Videos",
    "other": "Other",
    "total": "Total Media",
}


def ha_post(endpoint, data):
    """POST JSON to the HA REST API."""
    req = urllib.request.Request(
        f"{HA_URL}/api/{endpoint}",
        data=json.dumps(data).encode(),
        headers={
            "Authorization": f"Bearer {HA_TOKEN}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        print(f"  HA API error: {e.code} {e.reason}", file=sys.stderr)
        raise


def mqtt_publish(topic, payload, retain=True):
    """Publish a message to MQTT via HA's REST API."""
    ha_post("services/mqtt/publish", {
        "topic": topic,
        "payload": json.dumps(payload),
        "retain": retain,
    })


def safe_name(username):
    """Sanitize a username for use in MQTT topics and entity IDs."""
    return re.sub(r"[^a-zA-Z0-9_]", "_", username)


def publish_discovery(username):
    """Publish MQTT auto-discovery config for all metrics of a user."""
    sname = safe_name(username)
    state_topic = f"{STATE_TOPIC_PREFIX}/{sname}/state"
    device_id = f"synofoto_{sname}"

    for key, friendly in METRICS.items():
        unique_id = f"{device_id}_{key}"
        config_topic = f"{DISCOVERY_PREFIX}/sensor/{unique_id}/config"
        mqtt_publish(config_topic, {
            "name": friendly,
            "unique_id": unique_id,
            "state_topic": state_topic,
            "value_template": f"{{{{ value_json.{key} }}}}",
            "icon": "mdi:image-multiple",
            "device": {
                "identifiers": [device_id],
                "name": f"Synology Photos ({username})",
                "manufacturer": "synofoto-media-count",
            },
        })


def publish_state(username, counts):
    """Publish current media counts for a user."""
    topic = f"{STATE_TOPIC_PREFIX}/{safe_name(username)}/state"
    mqtt_publish(topic, counts)


def mark_unavailable(sname):
    """Mark a user's sensors as unavailable."""
    topic = f"{STATE_TOPIC_PREFIX}/{sname}/state"
    mqtt_publish(topic, {k: "" for k in METRICS})


def run_count_script(*args):
    """Run count-media.sh with the given arguments and return stdout."""
    cmd = [COUNT_SCRIPT] + list(args) + COUNT_EXTRA_ARGS
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def get_known_ha_users():
    """Query HA for existing synofoto sensor entities to find previously published users."""
    req = urllib.request.Request(
        f"{HA_URL}/api/states",
        headers={"Authorization": f"Bearer {HA_TOKEN}"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            states = json.loads(resp.read())
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"  WARNING: Could not query HA states ({e}), skipping stale user cleanup.", file=sys.stderr)
        return None

    users = set()
    for entity in states:
        m = re.match(r"sensor\.synology_photos_(.+)_total_media$", entity.get("entity_id", ""))
        if m:
            users.add(m.group(1))
    return users


def main():
    global VERBOSE
    VERBOSE = "--verbose" in sys.argv or "-v" in sys.argv

    if HA_TOKEN == "YOUR_LONG_LIVED_ACCESS_TOKEN_HERE":
        print("ERROR: Edit publish-to-ha.py and set HA_URL and HA_TOKEN.", file=sys.stderr)
        sys.exit(1)

    if not os.access(COUNT_SCRIPT, os.X_OK):
        print(f"ERROR: count-media.sh not found or not executable at: {COUNT_SCRIPT}", file=sys.stderr)
        sys.exit(1)

    # Get all Synology Photos users
    output = run_count_script("--list-users", "--json", "--all-users")
    if not output:
        print("ERROR: Failed to get user list.", file=sys.stderr)
        sys.exit(1)

    try:
        users = json.loads(output)
    except (json.JSONDecodeError, ValueError) as e:
        print(f"ERROR: Failed to parse user list JSON: {e}", file=sys.stderr)
        print(f"  Raw output: {output!r}", file=sys.stderr)
        sys.exit(1)
    log(f"Found {len(users)} user(s): {', '.join(u['name'] for u in users)}")

    published_users = set()
    for user in users:
        username = user["name"]
        log(f"  Processing: {username}")

        output = run_count_script("--user-name", username, "--json")
        if not output:
            log(f"    Skipped: no countable folders for {username}")
            continue

        try:
            counts = json.loads(output)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"    Skipped: invalid JSON from count-media.sh: {e}", file=sys.stderr)
            print(f"    Raw output: {output!r}", file=sys.stderr)
            continue
        publish_discovery(username)
        publish_state(username, counts)
        published_users.add(safe_name(username))
        log(f"    Published: {json.dumps(counts)}")

    # Clean up stale users
    known = get_known_ha_users()
    if known is not None:
        stale = known - published_users
        for sname in stale:
            log(f"  Marking stale user unavailable: {sname}")
            mark_unavailable(sname)

    log("Done.")


if __name__ == "__main__":
    main()
