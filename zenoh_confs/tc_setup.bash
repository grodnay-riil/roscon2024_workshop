#!/bin/bash
# Traffic shaping: 150 kbit/s total, UDP 7447 at 30 kbit/s high priority
set -e
tc qdisc del dev eth0 root 2>/dev/null || true
tc qdisc add dev eth0 root handle 1: htb default 20 r2q 1
tc class add dev eth0 parent 1:  classid 1:1  htb rate 150kbit ceil 150kbit
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 30kbit  ceil 30kbit  prio 0
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 120kbit ceil 150kbit prio 1
tc filter add dev eth0 parent 1: protocol ip u32 match ip protocol 17 0xff match ip dport 7447 0xffff flowid 1:10
tc filter add dev eth0 parent 1: protocol ip u32 match ip protocol 17 0xff match ip sport 7447 0xffff flowid 1:10
echo "tc setup done: 150kbit total, UDP 7447 at 30kbit prio 0"
