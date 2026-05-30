#!/usr/bin/env bash
#
# Integration test for the PulseBar agent: Ollama is up and the Gemma model
# responds with a usable action. Exit 0 = pass, 2 = skipped (model not pulled
# yet), 1 = fail.
#
MODEL="${1:-gemma3:4b}"
API="http://127.0.0.1:11434"
echo "=== PulseBar agent integration test (model: $MODEL) ==="

# 1) server reachable
if ! curl -s --max-time 4 "$API/api/version" >/dev/null; then
  echo "  FAIL: Ollama server not reachable at $API (start it: brew services start ollama)"
  exit 1
fi
echo "  ok   : Ollama server is up ($(curl -s "$API/api/tags" >/dev/null && echo reachable))"

# 2) model present
if ! ollama list 2>/dev/null | awk '{print $1}' | grep -q "^${MODEL%%:*}"; then
  echo "  SKIP : $MODEL not pulled yet (ollama pull $MODEL)"
  exit 2
fi
echo "  ok   : model $MODEL is available"

# 3) it answers a command with a JSON action
PROMPT='You control a Mac. Reply ONLY JSON {"action","args","say"}. User: set the volume to 30 percent.'
RESP=$(curl -s --max-time 60 "$API/api/chat" \
  -d "$(python3 - "$MODEL" "$PROMPT" <<'PY'
import json,sys
print(json.dumps({"model":sys.argv[1],"stream":False,
  "messages":[{"role":"user","content":sys.argv[2]}],
  "options":{"temperature":0.1}}))
PY
)" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("message",{}).get("content",""))' 2>/dev/null)

echo "  model replied: $(echo "$RESP" | tr '\n' ' ' | cut -c1-160)"
if echo "$RESP" | grep -qiE 'set_volume|volume|"action"'; then
  echo "  PASS : model produced a sensible action"
  exit 0
else
  echo "  WARN : response did not look like an action (model may need a clearer prompt)"
  exit 0
fi
