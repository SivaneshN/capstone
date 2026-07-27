#!/usr/bin/env python3
"""
One-off backfill: populate the archive with the last N days of historical
NASA APOD entries so the demo has real search history instead of just today.

Reuses src/apod_fetcher/handler.py's own functions (get_nasa_api_key,
extract_tags, first_sentence, copy_image_to_s3, write_tag_index, table)
directly, so the exact same Comprehend / local-heuristic tagging pipeline
runs for historical dates as for the daily Lambda invocation. Not part of
the deployed infrastructure -- run locally, once, against the already-
deployed table/bucket/secret named by the environment variables below.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import date, timedelta

DAYS_BACK = int(sys.argv[1]) if len(sys.argv) > 1 else 30

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "src", "apod_fetcher"))

import handler as fetcher  # noqa: E402


def fetch_apod_for_date(api_key, date_str):
    url = f"{fetcher.NASA_APOD_ENDPOINT}?api_key={api_key}&date={date_str}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read())


def backfill(days_back):
    api_key = fetcher.get_nasa_api_key()
    today = date.today()

    for offset in range(1, days_back + 1):
        target = today - timedelta(days=offset)
        date_str = target.strftime("%Y-%m-%d")

        try:
            apod = fetch_apod_for_date(api_key, date_str)
        except urllib.error.HTTPError as e:
            print(f"SKIP {date_str}: HTTP {e.code}")
            continue
        except urllib.error.URLError as e:
            print(f"SKIP {date_str}: {e.reason}")
            continue

        title = apod.get("title", "")
        explanation = apod.get("explanation", "")
        media_type = apod.get("media_type", "image")
        url = apod.get("url", "")
        hd_url = apod.get("hdurl", "")

        tags = fetcher.extract_tags(explanation)
        preview = fetcher.first_sentence(explanation)

        s3_key = ""
        if media_type == "image" and url:
            result = fetcher.copy_image_to_s3(url, date_str)
            if result:
                s3_key = result

        record = {
            "date": date_str,
            "title": title,
            "explanation": explanation,
            "url": url,
            "hd_url": hd_url,
            "media_type": media_type,
            "s3_key": s3_key,
            "tags": tags,
            "preview": preview,
            "fetched_at": fetcher.datetime.now(fetcher.timezone.utc).isoformat(),
        }

        fetcher.table.put_item(Item=record)
        fetcher.write_tag_index(tags, date_str)

        print(f"OK   {date_str}: {title!r} tags={tags}")
        time.sleep(1)  # be polite to the NASA API rate limit


if __name__ == "__main__":
    backfill(DAYS_BACK)
