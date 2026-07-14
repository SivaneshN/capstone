"""
apod-fetcher Lambda

Triggered daily by EventBridge. Pipeline:
  1. Read the NASA API key from Secrets Manager.
  2. Call the NASA APOD API for today's astronomy picture.
  3. Run the explanation text through Amazon Comprehend
     (DetectKeyPhrases + DetectEntities) to build a tags[] list.
  4. Write the enriched record to DynamoDB (partition key = date).
  5. If the entry is an image (not a video), copy it into S3.

Only Python stdlib + boto3 are used (both available in the default Lambda
runtime), so no dependency layer is required.
"""

import json
import logging
import os
import re
import urllib.request
import urllib.error
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
TAG_INDEX_TABLE_NAME = os.environ.get("TAG_INDEX_TABLE_NAME", "")
BUCKET_NAME = os.environ["BUCKET_NAME"]
SECRET_ARN = os.environ["SECRET_ARN"]
CONFIDENCE_THRESHOLD = float(os.environ.get("TAG_CONFIDENCE_THRESHOLD", "0.85"))
MAX_TAGS = int(os.environ.get("MAX_TAGS", "10"))

NASA_APOD_ENDPOINT = "https://api.nasa.gov/planetary/apod"

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
tag_index_table = dynamodb.Table(TAG_INDEX_TABLE_NAME) if TAG_INDEX_TABLE_NAME else None
s3 = boto3.client("s3")
comprehend = boto3.client("comprehend")
secretsmanager = boto3.client("secretsmanager")

# Cache the API key across warm invocations so we don't call Secrets Manager
# on every single run (still fetched fresh on every cold start).
_cached_api_key = None


def get_nasa_api_key():
    global _cached_api_key
    if _cached_api_key:
        return _cached_api_key

    response = secretsmanager.get_secret_value(SecretId=SECRET_ARN)
    secret = json.loads(response["SecretString"])
    _cached_api_key = secret["api_key"]
    return _cached_api_key


def fetch_apod(api_key):
    url = f"{NASA_APOD_ENDPOINT}?api_key={api_key}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read()
            return json.loads(body)
    except urllib.error.HTTPError as e:
        logger.error("NASA APOD API returned HTTP %s: %s", e.code, e.read())
        raise
    except urllib.error.URLError as e:
        logger.error("NASA APOD API request failed: %s", e.reason)
        raise


def first_sentence(text):
    """Return the first sentence of the explanation as a human-readable preview."""
    if not text:
        return ""
    match = re.search(r"(.+?[.!?])(\s|$)", text.strip())
    return match.group(1).strip() if match else text.strip()[:280]


_STOPWORDS = {
    "the", "and", "for", "with", "this", "that", "from", "into", "have",
    "has", "had", "are", "was", "were", "been", "being", "will", "would",
    "could", "should", "about", "which", "their", "there", "these", "those",
    "than", "then", "such", "some", "also", "more", "most", "less", "each",
    "every", "over", "under", "between", "through", "when", "where", "what",
    "while", "during", "after", "before", "above", "below", "here", "near",
}

# Common words that often start a sentence (and so get capitalized) but are
# not proper nouns. Excluded from the local fallback's phrase candidates —
# without this, "Although", "Earlier", "Besides", "Like" etc. get mistaken
# for entity names.
_NON_NOUN_SENTENCE_STARTERS = {
    "earlier", "although", "besides", "like", "with", "since", "however",
    "therefore", "meanwhile", "indeed", "thus", "then", "now", "today",
    "here", "there", "also", "both", "either", "neither", "until", "unless",
    "because", "while", "whether", "another", "other", "others", "some",
    "many", "most", "several", "various", "further", "first", "last",
    "next", "previous", "following", "above", "below", "still", "yet",
    "perhaps", "certainly", "generally", "typically", "usually", "often",
    "sometimes", "instead", "finally", "additionally", "moreover", "so",
    "but", "and", "or", "if", "when", "as", "though", "even", "just",
}


def local_extract_tags(text):
    """
    Lightweight, dependency-free stand-in for Comprehend, used only if the
    account's IAM role denies comprehend:DetectKeyPhrases /
    comprehend:DetectEntities (common in restricted sandbox/lab accounts).

    Approach:
      - Proper-noun-style phrases: runs of capitalized words (catches things
        like "Hubble Space Telescope", "Andromeda Galaxy") — same signal
        Comprehend's entity detection targets.
      - Frequent significant single words as a key-phrase substitute.
    Both are deduped case-insensitively and capped at MAX_TAGS.
    """
    if not text:
        return []

    proper_noun_runs = re.findall(r"\b[A-Z][a-zA-Z\-]*(?:\s+[A-Z][a-zA-Z\-]*)*\b", text)
    phrase_candidates = []
    for p in proper_noun_runs:
        words = p.strip().split()
        # Trim leading words that are common sentence-starters (handles both
        # single-word false positives like "Although" and glued cases like
        # "Besides Earth" where a sentence-starter directly precedes a real
        # proper noun with no punctuation between them).
        while words and words[0].lower() in _NON_NOUN_SENTENCE_STARTERS:
            words = words[1:]
        cleaned = " ".join(words)
        if len(cleaned) > 3:
            phrase_candidates.append(cleaned)

    words = re.findall(r"\b[a-zA-Z]{5,}\b", text.lower())
    freq = {}
    for w in words:
        if w in _STOPWORDS or w in _NON_NOUN_SENTENCE_STARTERS:
            continue
        freq[w] = freq.get(w, 0) + 1
    frequent_words = [w for w, count in sorted(freq.items(), key=lambda kv: -kv[1]) if count > 1]

    seen = set()
    tags = []
    for candidate in phrase_candidates + frequent_words:
        key = candidate.lower()
        if key in seen:
            continue
        seen.add(key)
        tags.append(candidate)

    return tags[:MAX_TAGS]


def extract_tags(explanation_text):
    """
    Run Comprehend key phrase extraction + entity recognition on the
    explanation text, merge the results, dedupe, filter by confidence,
    and cap at MAX_TAGS.

    Falls back to local_extract_tags() if the Lambda's IAM role isn't
    granted comprehend:DetectKeyPhrases / comprehend:DetectEntities (this
    happens in some restricted AWS Academy / Learner Lab accounts, where
    LabRole intentionally excludes AI/ML services). The fallback keeps the
    pipeline running end-to-end; swap to a role with Comprehend access to
    get true NLP-based tagging.
    """
    if not explanation_text:
        return []

    text = explanation_text[:4800]

    try:
        key_phrases_resp = comprehend.detect_key_phrases(Text=text, LanguageCode="en")
        entities_resp = comprehend.detect_entities(Text=text, LanguageCode="en")
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "AccessDeniedException":
            logger.warning(
                "Comprehend access denied for this IAM role — falling back to "
                "local tag extraction. Grant comprehend:DetectKeyPhrases and "
                "comprehend:DetectEntities to use real NLP tagging."
            )
            return local_extract_tags(text)
        raise

    candidates = []

    for phrase in key_phrases_resp.get("KeyPhrases", []):
        candidates.append((phrase["Text"], phrase["Score"]))

    for entity in entities_resp.get("Entities", []):
        candidates.append((entity["Text"], entity["Score"]))

    # Filter by confidence, dedupe case-insensitively (keep highest score,
    # keep original casing), preserve first-seen order.
    best_by_key = {}
    order = []
    for text_value, score in candidates:
        if score < CONFIDENCE_THRESHOLD:
            continue
        key = text_value.strip().lower()
        if not key:
            continue
        if key not in best_by_key or score > best_by_key[key][1]:
            best_by_key[key] = (text_value.strip(), score)
        if key not in order:
            order.append(key)

    tags = [best_by_key[key][0] for key in order]
    return tags[:MAX_TAGS]


def copy_image_to_s3(image_url, date_str):
    """Download the APOD image and store it in S3. Returns the s3_key, or None on skip/failure."""
    extension = image_url.split("?")[0].rsplit(".", 1)[-1]
    if len(extension) > 5 or "/" in extension:
        extension = "jpg"

    s3_key = f"apod-archive/{date_str}.{extension}"

    try:
        request = urllib.request.Request(image_url)
        with urllib.request.urlopen(request, timeout=20) as response:
            image_bytes = response.read()
            content_type = response.headers.get("Content-Type", "image/jpeg")
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        logger.error("Failed to download image for S3 archival: %s", e)
        return None

    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=s3_key,
        Body=image_bytes,
        ContentType=content_type,
    )
    return s3_key


def write_tag_index(tags, date_str):
    """
    Write one sparse-index item per tag: {tag (lowercased, PK), date (SK),
    original_tag}. Lets apod-query do an O(1) Query instead of a full Scan.
    No-op if TAG_INDEX_TABLE_NAME wasn't provided.
    """
    if not tag_index_table:
        return
    for tag in tags:
        try:
            tag_index_table.put_item(Item={
                "tag": tag.strip().lower(),
                "date": date_str,
                "original_tag": tag,
            })
        except Exception:  # noqa: BLE001
            logger.exception("Failed to write tag-index entry for tag=%s date=%s", tag, date_str)


def lambda_handler(event, context):
    api_key = get_nasa_api_key()
    apod = fetch_apod(api_key)

    date_str = apod.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    title = apod.get("title", "")
    explanation = apod.get("explanation", "")
    media_type = apod.get("media_type", "image")
    url = apod.get("url", "")
    hd_url = apod.get("hdurl", "")

    logger.info("Fetched APOD for %s: %s (%s)", date_str, title, media_type)

    tags = extract_tags(explanation)
    preview = first_sentence(explanation)

    s3_key = ""
    if media_type == "image" and url:
        result = copy_image_to_s3(url, date_str)
        if result:
            s3_key = result
    else:
        logger.info("Skipping S3 copy: media_type=%s", media_type)

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
        "fetched_at": datetime.now(timezone.utc).isoformat(),
    }

    table.put_item(Item=record)
    logger.info("Wrote enriched record for %s with %d tags", date_str, len(tags))

    write_tag_index(tags, date_str)

    return {
        "statusCode": 200,
        "body": json.dumps({"date": date_str, "tags": tags, "s3_key": s3_key}),
    }
