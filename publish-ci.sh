#!/usr/bin/env bash
# Publish the next queued deck to Instagram. Runs in GitHub Actions.
#
# Reads queue.txt in order, skips anything already listed in published.txt,
# publishes the first one left, then records it.
#
# Env (from repository secrets):
#   IG_USER_ID, IG_ACCESS_TOKEN
set -eu

GRAPH="https://graph.instagram.com/${GRAPH_VERSION:-v21.0}"
RAW="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_REF_NAME:-main}"

[ -n "${IG_USER_ID:-}" ]      || { echo "IG_USER_ID secret not set"; exit 1; }
[ -n "${IG_ACCESS_TOKEN:-}" ] || { echo "IG_ACCESS_TOKEN secret not set"; exit 1; }

touch queue.txt published.txt

DECK=""
while IFS= read -r line; do
  line="$(printf '%s' "$line" | tr -d ' \r')"
  [ -n "$line" ] || continue
  grep -qxF "$line" published.txt && continue
  DECK="$line"; break
done < queue.txt

if [ -z "$DECK" ]; then
  echo "queue is empty — nothing left to publish."
  echo "Add more decks with sync-to-repo.sh."
  exit 0
fi

echo "publishing: $DECK"
[ -d "img/$DECK" ] || { echo "img/$DECK is missing"; exit 1; }
[ -s "img/$DECK/caption.txt" ] || { echo "img/$DECK/caption.txt is missing"; exit 1; }

COUNT="$(ls img/"$DECK"/card-*.jpg | wc -l | tr -d ' ')"
if [ "$COUNT" -lt 2 ] || [ "$COUNT" -gt 10 ]; then
  echo "carousels take 2-10 images, $DECK has $COUNT"; exit 1
fi
echo "  $COUNT cards"

api_id() {
  local resp="$1" what="$2" id
  id="$(printf '%s' "$resp" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
  if [ -z "$id" ]; then
    echo "$what failed:" >&2
    printf '%s\n' "$resp" | sed -n 's/.*"message":"\([^"]*\)".*/  -> \1/p' >&2
    printf '%s\n' "$resp" >&2
    exit 1
  fi
  printf '%s' "$id"
}

# 1. one container per card
CHILDREN=""
for f in img/"$DECK"/card-*.jpg; do
  url="$RAW/$f?v=$(date +%s)"
  resp="$(curl -sS -X POST "$GRAPH/$IG_USER_ID/media" \
            --data-urlencode "image_url=$url" \
            -d "is_carousel_item=true" \
            -d "access_token=$IG_ACCESS_TOKEN")"
  CHILDREN="${CHILDREN:+$CHILDREN,}$(api_id "$resp" "carousel item")"
done

# 2. the carousel
CAPTION="$(cat img/"$DECK"/caption.txt)"
resp="$(curl -sS -X POST "$GRAPH/$IG_USER_ID/media" \
          -d "media_type=CAROUSEL" \
          -d "children=$CHILDREN" \
          --data-urlencode "caption=$CAPTION" \
          -d "access_token=$IG_ACCESS_TOKEN")"
CREATION_ID="$(api_id "$resp" "carousel container")"

# 3. publish
resp="$(curl -sS -X POST "$GRAPH/$IG_USER_ID/media_publish" \
          -d "creation_id=$CREATION_ID" \
          -d "access_token=$IG_ACCESS_TOKEN")"
MEDIA_ID="$(api_id "$resp" "publish")"

echo "$DECK" >> published.txt
echo "published — media id $MEDIA_ID"

REMAINING="$(grep -vxF -f published.txt queue.txt 2>/dev/null | grep -c . || true)"
echo "decks left in queue: ${REMAINING:-0}"
