# Make Cloudflare hold exactly the public A records kakapo's LAN proxy serves.
#
#   ZONE     the Cloudflare zone, e.g. salehtl.com
#   ADDRESS  the address every name points at
#   NAMES    space-separated FQDNs that should exist
#   TAG      comment prefix that marks a record as kakapo's
#   token    $CREDENTIALS_DIRECTORY/token
#
# The zone also holds records kakapo must never touch (iCloud mail: MX, SPF,
# DKIM, DMARC). Only records whose comment starts with TAG are kakapo's: they
# are created, corrected and deleted here. Anything else at a wanted name is a
# conflict, reported and left alone. The server-side comment filter is
# re-checked client-side before every delete.

api=https://api.cloudflare.com/client/v4

# The token reaches curl through --config on a pipe, never argv.
cf() {
  curl -fsS --config <(printf 'header = "Authorization: Bearer %s"\n' "$(<"$CREDENTIALS_DIRECTORY/token")") \
    -H 'Content-Type: application/json' "$@"
}

ours() { jq -c --arg tag "$TAG" '[.[] | select(.type == "A" and ((.comment // "") | startswith($tag)))]'; }

zone_id=$(cf --get "$api/zones" --data-urlencode "name=$ZONE" | jq -er '.result[0].id')
failed=0

for name in $NAMES; do
  # Every record at this exact name, any type.
  at_name=$(cf --get "$api/zones/$zone_id/dns_records" --data-urlencode "name=$name" --data-urlencode per_page=100 |
    jq -c --arg n "$name" '[.result[] | select(.name == $n)]')
  mine=$(ours <<<"$at_name")
  foreign=$(jq -c --arg tag "$TAG" '[.[] | select((.comment // "") | startswith($tag) | not)]' <<<"$at_name")

  if [ "$(jq length <<<"$foreign")" -gt 0 ]; then
    echo "$name already has records kakapo does not manage ($(jq -r '[.[] | .type] | join(", ")' <<<"$foreign")); leaving it alone" >&2
    failed=1
    continue
  fi

  want=$(jq -nc --arg n "$name" --arg ip "$ADDRESS" --arg tag "$TAG" \
    '{type: "A", name: $n, content: $ip, ttl: 300, proxied: false, comment: $tag}')
  case $(jq length <<<"$mine") in
  0)
    cf -X POST "$api/zones/$zone_id/dns_records" --data "$want" >/dev/null
    echo "created $name -> $ADDRESS"
    ;;
  1)
    if jq -e --arg ip "$ADDRESS" --arg tag "$TAG" '.[0] | .content == $ip and .proxied == false and .comment == $tag' <<<"$mine" >/dev/null; then
      echo "$name already -> $ADDRESS"
    else
      cf -X PUT "$api/zones/$zone_id/dns_records/$(jq -r '.[0].id' <<<"$mine")" --data "$want" >/dev/null
      echo "corrected $name -> $ADDRESS"
    fi
    ;;
  *)
    echo "$name has $(jq length <<<"$mine") kakapo A records; refusing to guess which to keep" >&2
    failed=1
    ;;
  esac
done

# Prune kakapo's records for names no longer served.
managed=$(cf --get "$api/zones/$zone_id/dns_records" --data-urlencode type=A \
  --data-urlencode "comment.startswith=$TAG" --data-urlencode per_page=100 | jq -c '.result' | ours)
while read -r id name; do
  [ -n "$id" ] || continue
  case " $NAMES " in
  *" $name "*) ;;
  *)
    cf -X DELETE "$api/zones/$zone_id/dns_records/$id" >/dev/null
    echo "removed $name"
    ;;
  esac
done < <(jq -r '.[] | "\(.id) \(.name)"' <<<"$managed")

exit "$failed"
