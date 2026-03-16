#!/bin/bash
tc qdisc del dev eth0 root 2>/dev/null
echo "tc reset done"
