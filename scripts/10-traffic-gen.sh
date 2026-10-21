#!/bin/sh
# Step 10: varied synthetic traffic for Kong Cloud — 7 routes, 5 consumers, anonymous calls,
# methods, status codes, /delay latency, /bytes payloads, rate-limit bursts. Runs forever (`make traffic`).
P="${KONG_SERVERLESS_URL:?}"
rnd() { od -An -N2 -tu2 /dev/urandom | tr -d ' '; }
pick() { n=$#; i=$(( $(rnd) % n + 1 )); eval echo "\${$i}"; }
call() { curl -s -o /dev/null -m 15 -X "$1" ${3:+-H "apikey: $3"} "$P$2"; }
i=0
while :; do
  i=$((i+1)); r=$(rnd); p=$((r % 100))
  # consumer mix (weighted): web-app > mobile-app > partner > batch > bro > anonymous
  w=$((r % 20))
  if   [ $w -lt 7 ];  then K="$KEY_WEB_APP"
  elif [ $w -lt 12 ]; then K="$KEY_MOBILE_APP"
  elif [ $w -lt 15 ]; then K="$KEY_PARTNER_ACME"
  elif [ $w -lt 17 ]; then K="$KEY_INTERNAL_BATCH"
  elif [ $w -lt 19 ]; then K="$KEY_BRO"
  else K=""; fi
  route=$(pick orders orders orders payments payments users catalog catalog search search legacy)
  [ "$K" = "$KEY_BRO" ] && route=test
  if   [ $p -lt 45 ]; then call GET  "/$route/get" "$K"
  elif [ $p -lt 60 ]; then call POST "/$route/post" "$K"
  elif [ $p -lt 65 ]; then call PUT  "/$route/put" "$K"
  elif [ $p -lt 68 ]; then call DELETE "/$route/delete" "$K"
  elif [ $p -lt 76 ]; then call GET  "/$route/delay/$((r % 4))" "$K"
  elif [ $p -lt 82 ]; then call GET  "/$route/bytes/$(( (r % 80 + 1) * 1024 ))" "$K"
  elif [ $p -lt 87 ]; then call GET  "/$route/status/404" "$K"
  elif [ $p -lt 90 ]; then call GET  "/$route/status/500" "$K"
  elif [ $p -lt 92 ]; then call GET  "/$route/status/502" "$K"
  elif [ $p -lt 95 ]; then call GET  "/$route/status/400" "$K"
  else call POST "/$route/status/201" "$K"; fi
  # burst on /search every ~10 min to trip the rate limit
  if [ $((i % 1200)) -lt 80 ]; then call GET /search/get "$KEY_PARTNER_ACME" & sleep 0.05; else sleep 0.3; fi
done
