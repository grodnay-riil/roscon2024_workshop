#!/bin/bash
# Bandwidth test: 200 blocked topics + 1 allowed at 100Hz
# Run inside container-a with router already running

set -e
source /rmw_zenoh_env.bash
export ZENOH_ROUTER_CHECK_ATTEMPTS=-1

NUM_BLOCKED=200
DURATION=30

echo "=== Bandwidth Test ==="
echo "Launching $NUM_BLOCKED blocked publishers (/blocked_N) at 1Hz..."
for i in $(seq 1 $NUM_BLOCKED); do
  ros2 topic pub --rate 1 /blocked_$i std_msgs/msg/String "data: blocked_$i" &>/dev/null &
done

echo "Launching 1 allowed publisher (/chatter_public) at 100Hz..."
PAYLOAD=$(python3 -c "print('X' * 1000)")
ros2 topic pub --rate 100 /chatter_public std_msgs/msg/String "{data: '$PAYLOAD'}" &>/dev/null &

echo "Waiting 30s for all publishers to register and discovery burst to settle..."
sleep 30

echo ""
echo "--- Measuring eth0 TX for ${DURATION}s ---"
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_bytes)
sleep $DURATION
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_bytes)

TX_DIFF=$((TX_AFTER - TX_BEFORE))
TX_KBPS=$(( TX_DIFF * 8 / DURATION / 1000 ))

echo "TX bytes: $TX_DIFF over ${DURATION}s"
echo "TX rate:  ${TX_KBPS} kbit/s"
echo ""
echo "Cleaning up..."
kill $(jobs -p) 2>/dev/null
wait 2>/dev/null
echo "Done."
