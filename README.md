# NASA Space Image Archive & Intelligent Tagger

Team **Error_404** · AWS Learner Lab · `us-east-1` · Terraform · Serverless

A daily-growing, searchable archive of NASA's Astronomy Picture of the Day (APOD),
enriched with AI-generated tags via Amazon Comprehend. Built entirely with Terraform.

## What it does

Every day, an EventBridge cron rule triggers the **apod-fetcher** Lambda, which:

1. Reads the NASA API key from Secrets Manager.
2. Calls the [NASA APOD API](https://api.nasa.gov/planetary/apod) for today's title, explanation, and media URL.
3. Runs the explanation text through Amazon Comprehend (`DetectKeyPhrases` + `DetectEntities`) to
   build a deduped `tags[]` array (filtered by confidence threshold, capped at `MAX_TAGS`), and
   derives a `preview` from the first sentence of the explanation.
4. Writes the enriched record to DynamoDB (partition key `date`) and copies the image to S3
   (skipped for `media_type = "video"` entries).
5. Writes a sparse per-tag index entry (`tag`, `date`) to a second DynamoDB table so tag lookups
   are O(1) partition queries instead of full table scans.

A second Lambda, **apod-query**, is fronted by an HTTP API Gateway and exposes:

- `GET /today` — today's enriched record.
- `GET /search?tag=X` — all archived records tagged `X` (case-insensitive), newest first.

CloudWatch logs both functions and a dashboard tracks fetch success, Comprehend latency, and
DynamoDB write errors.

## Architecture

```
NASA APOD API
     |
     | daily @ 08:00 UTC (EventBridge cron)
     v
[Lambda: apod-fetcher] --explanation text--> [Amazon Comprehend]
     |                  <--phrases + entities--
     |-- writes enriched record --> [DynamoDB: apod-archive-records]
     |-- writes per-tag entries --> [DynamoDB: apod-archive-tag-index]
     |-- copies image (if any)  --> [S3: apod-archive/YYYY-MM-DD.<ext>]
     |
[Secrets Manager] --NASA API key (cold start)--

User Request --> [API Gateway] --> [Lambda: apod-query]
                                        |-- GET /today        -> DynamoDB GetItem
                                        |-- GET /search?tag=X -> tag-index Query -> DynamoDB GetItem(s)
                                        v
                                  JSON response

[CloudWatch] Logs (both functions) + Dashboard (fetch success, Comprehend latency, write errors)
```

## AWS services used

| Role | Service | Notes |
|---|---|---|
| Compute | Lambda | `apod-fetcher` (scheduled pipeline), `apod-query` (API handler) |
| External integration | API Gateway (HTTP API) | `GET /today`, `GET /search?tag=` |
| Persistent state | DynamoDB | `<project>-records` (main archive) + `<project>-tag-index` (sparse tag lookup) |
| Persistent state | S3 | Archived images at `apod-archive/YYYY-MM-DD.<ext>` |
| Secret management | Secrets Manager | Stores the NASA API key, fetched (and cached) at cold start |
| Schedule trigger | EventBridge | Daily cron rule, default `08:00 UTC` |
| Intelligence | Amazon Comprehend | Key phrase + entity extraction, drives `tags[]` |
| Observability | CloudWatch | Logs for both Lambdas + a dashboard |

Note: `extract_tags()` in `apod-fetcher` falls back to a lightweight local heuristic
(proper-noun + frequent-word extraction) if the Lambda's IAM role lacks Comprehend
permissions — common on restricted AWS Academy / Learner Lab `LabRole`s — so the pipeline
still runs end-to-end without real Comprehend access.

## Repository layout

```
capstone/
├── main.tf                    # Wires all modules together
├── variables.tf                # aws_region, project_name, nasa_api_key, schedule_cron, ...
├── outputs.tf                  # API URLs, table/bucket names, dashboard URL
├── terraform.tfvars             # Local config (gitignored — holds the NASA API key)
├── modules/
│   ├── lambda/                  # apod_fetcher.tf, apod_query.tf
│   ├── api_gateway/              # api.tf — HTTP API + routes
│   ├── dynamodb/                 # table.tf — records table + tag-index table
│   ├── s3/                       # bucket.tf — image archive bucket
│   ├── secrets_manager/          # nasa_key.tf
│   ├── eventbridge/               # schedule.tf — daily cron rule
│   └── cloudwatch/                # dashboard.tf
└── src/
    ├── apod_fetcher/handler.py    # Fetch -> Comprehend -> DynamoDB + S3
    └── apod_query/handler.py      # /today and /search?tag= handlers
```

## Deploying

1. Get a free NASA API key at https://api.nasa.gov.
2. Copy `terraform.tfvars` (see the template comments in the file) and set `nasa_api_key`.
   If deploying in an AWS Academy / Learner Lab account that blocks IAM role creation, also
   set `lab_role_arn` to your account's `LabRole` ARN.
3. Run:
   ```
   terraform init
   terraform apply
   ```
4. Terraform outputs the API base URL, `/today` and `/search?tag=` example endpoints, table
   names, bucket name, and the CloudWatch dashboard URL.

## Configuration

Key variables (see `variables.tf` for the full list and defaults):

| Variable | Default | Purpose |
|---|---|---|
| `schedule_cron` | `cron(0 8 * * ? *)` | When `apod-fetcher` runs daily |
| `tag_confidence_threshold` | `0.85` | Minimum Comprehend confidence to keep a tag |
| `max_tags` | `10` | Max tags stored per record |
| `log_retention_days` | `14` | CloudWatch Logs retention |
| `lab_role_arn` | `null` | Use an existing IAM role instead of creating one (Learner Lab) |

## Cost

Estimated well under $5/month at the traffic levels used here (~31 fetcher runs/month,
~500 query calls/month) — see the capstone proposal for the full per-service breakdown.
