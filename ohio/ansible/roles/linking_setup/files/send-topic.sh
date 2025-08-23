#!/bin/bash

cat <<EOF | /bin/kafka-console-producer \
  --bootstrap-server ec2-3-35-199-84.ap-northeast-2.compute.amazonaws.com:29092 \
  --topic test-link-cluster2 \
  --property "parse.key=true" \
  --property "key.separator=:"
key1:cluster2-test1
key2:cluster2-test2
key3:cluster2-test3
key4:cluster2-test4
key5:cluster2-test5
key6:cluster2-test6
key7:cluster2-test7
key8:cluster2-test8
key9:cluster2-test9
key10:cluster2-test10
EOF