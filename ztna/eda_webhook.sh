#!/bin/sh
echo "$(date) ARGS: $@" >> /tmp/webhook_debug.log
echo "$(date) ARG1='$1' ARG2='$2' ARG3='$3' ARG4='$4' ARG5='$5'" >> /tmp/webhook_debug.log
curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
-d "{\"switch_name\": \"$1\", \"switch_ip\": \"$2\", \"mac_address\": \"$3\", \"sgt\": \"$4\", \"interface\": \"$5\", \"status\": \"MAB_Authenticated\"}" \
http://24.211.217.45:5000/endpoint >> /tmp/webhook_debug.log 2>&1
