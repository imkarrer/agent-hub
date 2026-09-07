#!/usr/bin/env bash
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8091/health)
  echo "attempt $i: $code"
  if [ "$code" = "200" ]; then
    exit 0
  fi
  sleep 3
done
exit 1
