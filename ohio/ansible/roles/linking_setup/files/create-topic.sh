#!/bin/bash

/bin/kafka-topics \
  --bootstrap-server ec2-3-35-199-84.ap-northeast-2.compute.amazonaws.com:29092 \
  --create \
  --topic test-link-cluster2 \
  --partitions 1 \
  --replication-factor 3