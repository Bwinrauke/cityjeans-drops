#!/usr/bin/env bash
# Push web/ to the Supabase `web` bucket, which the `app` edge function serves.
# Usage:  SUPABASE_ADMIN_PASSWORD='...' ./scripts/deploy_web.sh
set -euo pipefail

URL="https://nrncccfqgwxcugqdouvs.supabase.co"
KEY="sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a"
EMAIL="${SUPABASE_ADMIN_EMAIL:-ben@cityjeans.com}"
PASS="${SUPABASE_ADMIN_PASSWORD:?set SUPABASE_ADMIN_PASSWORD}"

JWT=$(curl -fsS -X POST "$URL/auth/v1/token?grant_type=password" \
  -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

upload () {
  curl -fsS -X POST "$URL/storage/v1/object/web/$1" \
    -H "apikey: $KEY" -H "Authorization: Bearer $JWT" \
    -H "Content-Type: $2" -H "x-upsert: true" -H "cache-control: max-age=60" \
    --data-binary "@docs/$1" -o /dev/null
  echo "uploaded $1"
}

upload index.html "text/html"
upload admin.html "text/html"
upload config.js  "application/javascript"
echo "done — live at $URL/functions/v1/app/"
