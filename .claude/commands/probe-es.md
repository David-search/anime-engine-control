---
description: Hit the live AniChan Elasticsearch cluster (read-only)
argument-hint: <verb-and-path>  e.g. "GET /anime/_count"  or  "GET /_cat/indices?v"
---

Queries the AniChan ES over its external port (`70.30.158.46:43505`,
`elastic` auth). The index is `anime` (search_as_you_type suggest;
genres/tags/source/season facets; multilingual title search across
en + romaji + native).

```bash
set -a && source .env && set +a
ARG="${ARGUMENTS:-GET /_cat/indices?v}"

ES_BASE="http://$SSH_HOST:43505"
AUTH="$ELASTIC_USER:$ELASTIC_PASSWORD"

VERB=$(echo "$ARG" | awk '{print $1}')
PATH_PART=$(echo "$ARG" | cut -d' ' -f2-)

case "$VERB" in
  GET|HEAD)
    curl -sS -u "$AUTH" "$ES_BASE$PATH_PART"
    ;;
  POST|PUT)
    echo "ERROR: $VERB blocked from this command. Use a write-explicit slash command if you really need it."
    exit 1
    ;;
  *)
    # Default to GET — treat the whole arg as the path
    curl -sS -u "$AUTH" "$ES_BASE$ARG"
    ;;
esac
```

Handy probes:

```bash
GET /anime/_count
GET /anime/_search?size=1
GET /_cat/indices?v
```

For an autosuggest spot-check (search_as_you_type on titles), build the
curl call directly with a body:

```bash
set -a && source .env && set +a
curl -sS -u "$ELASTIC_USER:$ELASTIC_PASSWORD" \
  "http://$SSH_HOST:43505/anime/_search" \
  -H 'content-type: application/json' -d '{
    "size": 5,
    "query": {"multi_match": {
      "query": "naru",
      "type": "bool_prefix",
      "fields": ["suggest","suggest._2gram","suggest._3gram"]
    }}
  }'
```

DELETE is intentionally not supported. For complex queries with bodies,
construct the curl call directly using `http://$SSH_HOST:43505` and
`$ELASTIC_USER:$ELASTIC_PASSWORD` from the env.
