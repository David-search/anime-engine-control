---
description: Open a MongoDB shell against anime_db (or run a one-shot query)
---

Connects to the AniChan Mongo over its external port
(`70.30.158.46:43829`, `admin` auth, db `anime_db`).

```bash
set -a && source .env && set +a
# MONGO_URI in the env points at the in-network host (mongodb:27017).
# From a laptop, swap the host:port for the external one:
URI=$(echo "$MONGO_URI" | sed "s#@mongodb:27017#@$SSH_HOST:43829#")
mongosh "$URI"
```

Drops you into the `anime_db` database. Useful one-liners:

```js
show collections
// catalog, users, comments, likes, history
db.anime.countDocuments({})
db.anime.findOne({}, {idMal: 1, title: 1, genres: 1})
db.anime.countDocuments({characters: {$exists: true}})   // enrich coverage
db.comments.countDocuments({})
db.users.countDocuments({})
```

If `mongosh` isn't installed locally, run it on the server instead via
the `mongodb` container (in-network name, no port swap needed):

```bash
set -a && source .env && set +a
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  "docker exec mongodb mongosh '$MONGO_URI' --quiet --eval 'db.anime.countDocuments({})'"
```

`mongosh` is a read+write client. Be careful with mutating commands —
`anime_db` is the live catalog. Collections: `anime` (catalog), `users`,
`comments`, `likes`, `history`.
