#!/bin/bash

/bin/kafka-mirrors \
  --create \
  --mirror-topic test-link-cluster1 \
  --link link-link \
  --replication-factor 3 \
  --bootstrap-server ec2-18-189-168-183.us-east-2.compute.amazonaws.com:29092