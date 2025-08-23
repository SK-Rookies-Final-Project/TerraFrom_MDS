#!/bin/bash

# Kafka Cluster Link 생성 스크립트 (브로커 1번)
/bin/kafka-cluster-links \
  --bootstrap-server ec2-18-189-168-183.us-east-2.compute.amazonaws.com:29092 \
  --create \
  --link link-link \
  --config-file /home/appuser/link-link.config
