#!/usr/bin/env bash
# End-to-end proof that the embedding model and Qdrant work together: embed
# three sentences through /v1/embeddings, upsert them into a throwaway
# collection, search it with a fourth sentence, and check the nearest hit is
# the one a person would pick. Leaves nothing behind. Needs curl and jq.
#
#   vectors-smoke.sh                       # ac-box's addresses
#   LLM=127.0.0.1:8100 QDRANT=127.0.0.1:6333 vectors-smoke.sh
#
# The first call loads the embedding model if llama-swap does not have it up
# (a few seconds; it is 0.6 GB). The model name is the key homelab gives it
# in services.agent-hub.llm.models; override with MODEL if that changes.
set -euo pipefail

LLM="${LLM:-192.168.1.50:8100}"
QDRANT="${QDRANT:-192.168.1.50:6333}"
MODEL="${MODEL:-embed}"
COLL="smoke-$$"

embed() { # embed <json array of strings> -> json array of vectors
  curl -sf "http://${LLM}/v1/embeddings" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"input\":$1}" | jq -c '[.data[].embedding]'
}

DOCS='["a tier is a named share of the box: memory ceiling and CPU weight",
       "the DOWNTIME build applies the staged tenant tree in the 03:00 window",
       "the kids play on the arcade cabinet after school"]'
QUERY='["when does a queued deploy actually reach the box?"]'

echo "== embed 3 documents via ${LLM} (model ${MODEL})"
VECS=$(embed "$DOCS")
DIM=$(jq '.[0] | length' <<<"$VECS")
echo "   ${DIM}-dim vectors"

echo "== collection ${COLL} on ${QDRANT}"
trap 'curl -sf -X DELETE "http://${QDRANT}/collections/${COLL}" >/dev/null && echo "== dropped ${COLL}"' EXIT
curl -sf -X PUT "http://${QDRANT}/collections/${COLL}" -H 'Content-Type: application/json' \
  -d "{\"vectors\":{\"size\":${DIM},\"distance\":\"Cosine\"}}" >/dev/null

POINTS=$(jq -c --argjson d "$DOCS" '{points: [range(length) as $i | {id: ($i+1), vector: .[$i], payload: {text: $d[$i]}}]}' <<<"$VECS")
curl -sf -X PUT "http://${QDRANT}/collections/${COLL}/points?wait=true" -H 'Content-Type: application/json' \
  -d "$POINTS" >/dev/null
echo "   3 points upserted"

echo "== search: $(jq -r '.[0]' <<<"$QUERY")"
QV=$(embed "$QUERY" | jq -c '.[0]')
HITS=$(curl -sf "http://${QDRANT}/collections/${COLL}/points/search" -H 'Content-Type: application/json' \
  -d "{\"vector\":${QV},\"limit\":3,\"with_payload\":true}")
jq -r '.result[] | "   \(.score | . * 1000 | round / 1000)  \(.payload.text)"' <<<"$HITS"

TOP=$(jq -r '.result[0].id' <<<"$HITS")
if [ "$TOP" = 2 ]; then
  echo "PASS - the DOWNTIME sentence is the nearest hit"
else
  echo "FAIL - expected point 2 nearest, got ${TOP}"; exit 1
fi
