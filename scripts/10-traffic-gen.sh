#!/bin/sh
# Step 10: mixed synthetic traffic for the Kong Cloud demo route (/test -> httpbin).
# Methods, status codes, latency (/delay), payload sizes (/bytes) and unauthenticated calls,
# ~2 req/s with a short burst every ~10 min. Runs forever (see `make traffic`).
U="${KONG_SERVERLESS_URL:?}/test"; K="${KONG_TESTER_APIKEY:?}"
req()  { curl -s -o /dev/null -m 15 -X "$1" -H "apikey: $K" "$U$2"; }
anon() { curl -s -o /dev/null -m 15 "$U$1"; }
i=0
while :; do
  i=$((i+1))
  r=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  p=$((r % 100))
  if   [ $p -lt 40 ]; then req GET /get
  elif [ $p -lt 50 ]; then req POST /post
  elif [ $p -lt 55 ]; then req PUT /put
  elif [ $p -lt 58 ]; then req DELETE /delete
  elif [ $p -lt 66 ]; then req GET "/delay/$((r % 3))"
  elif [ $p -lt 72 ]; then req GET "/bytes/$(( (r % 50 + 1) * 1024 ))"
  elif [ $p -lt 77 ]; then req GET /status/404
  elif [ $p -lt 80 ]; then req GET /status/429
  elif [ $p -lt 83 ]; then req GET /status/500
  elif [ $p -lt 85 ]; then req GET /status/503
  elif [ $p -lt 92 ]; then anon /get
  else req POST /status/201
  fi
  if [ $((i % 1200)) -lt 60 ]; then sleep 0.1; else sleep 0.5; fi
done
