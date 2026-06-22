---
description: Smoke-test the catalog/search API against the deployed backend
---

The catalog/search contract that must stay green after any search-code
change (`work/backend/app/...` services/routes that read Mongo/ES). Hits
the public backend and asserts each endpoint returns **200** with a
**non-empty** body. The request path is pure Mongo/ES reads, so a green
run means the index + data layer are wired correctly.

```bash
set -a && source .env && set +a
BASE="$BACKEND_URL"   # http://70.30.158.46:43577

fail=0
check() {
  local name="$1" url="$2"
  local body code
  body="$(curl -fsS -w $'\n%{http_code}' "$url" 2>/dev/null)" || { echo "FAIL $name — request error ($url)"; fail=1; return; }
  code="$(printf '%s' "$body" | tail -n1)"
  body="$(printf '%s' "$body" | sed '$d')"
  # non-empty == more than a bare [] / {} / null
  local trimmed; trimmed="$(printf '%s' "$body" | tr -d '[:space:]')"
  if [ "$code" = "200" ] && [ -n "$trimmed" ] && [ "$trimmed" != "[]" ] && [ "$trimmed" != "{}" ] && [ "$trimmed" != "null" ]; then
    echo "PASS $name ($code, $(printf '%s' "$body" | wc -c | tr -d ' ') bytes)"
  else
    echo "FAIL $name — code=$code body=${trimmed:0:80}"
    fail=1
  fi
}

check "popular"  "$BASE/api/catalog/popular"
check "search"   "$BASE/api/catalog/search?q=naruto"
check "browse"   "$BASE/api/catalog/browse?genre=Action"

# detail: pull one id from popular, then fetch its detail
ID="$(curl -fsS "$BASE/api/catalog/popular" 2>/dev/null \
      | grep -oE '"id"[: ]*[0-9]+' | head -n1 | grep -oE '[0-9]+')"
if [ -n "$ID" ]; then
  check "anime/$ID" "$BASE/api/catalog/anime/$ID"
else
  echo "SKIP anime/{id} — could not extract an id from /popular"; fail=1
fi

echo
[ "$fail" -eq 0 ] && echo "all green" || { echo "FAILURES above"; exit 1; }
```

Exit 0 = all green; non-zero = at least one endpoint failed (listed
above with its code/body). Endpoints exercised:

- `GET /api/catalog/popular` — popularity head of the catalog
- `GET /api/catalog/search?q=` — ES search
- `GET /api/catalog/browse?genre=` — facet/genre browse
- `GET /api/catalog/anime/{id}` — single-doc detail (id = AniList id)

Run this after every change to search/catalog code and after
[`/deploy-backend`](deploy-backend.md) lands. If `/popular` is empty,
the catalog hasn't been ingested yet — run [`/ingest`](ingest.md) first.
