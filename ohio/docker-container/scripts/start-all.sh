#!/bin/bash

wait_for_kafka() {
  echo "⏳ Waiting for Kafka broker on $1 ..."
  while ! nc -z $1 $2; do
    sleep 1
  done
  echo "✅ Kafka broker $1:$2 is ready!"
}

wait_for_kafka_ready() {
  echo "⏳ Waiting for Kafka metadata to be available..."
  until docker exec broker1 kafka-topics --bootstrap-server broker1:29092 --list &>/dev/null; do
    sleep 10
  done

  until docker exec broker2 kafka-topics --bootstrap-server broker2:39092 --list &>/dev/null; do
    sleep 10
  done

  until docker exec broker3 kafka-topics --bootstrap-server broker3:49092 --list &>/dev/null; do
    sleep 10
  done

  echo "✅ Kafka metadata is available!"
}


echo "✅ Step 1: Starting Kafka Controllers (controller1~3)..."
docker compose -f ../inventory/docker-compose-kr.yml up -d
sleep 10

echo "✅ Step 2: Starting Kafka Brokers (broker1~3)..."
docker compose -f ../inventory/docker-compose-br.yml up -d

# Wait for Kafka brokers to be ready
wait_for_kafka localhost 29092
wait_for_kafka localhost 39092
wait_for_kafka localhost 49092

wait_for_kafka_ready

echo "✅ Step 3: Starting Kafka Connect Workers (kafka-connect1, kafka-connect2)..."
docker compose -f ../inventory/docker-compose-cw.yml up -d
sleep 20

echo "✅ Step 4: Starting Schema Registry (schema-registry1, schema-registry2)..."
docker compose -f ../inventory/docker-compose-sr.yml up -d
sleep 15

echo "✅ Step 5: Starting ksqlDB (ksqldb, ksqldb-cli)..."
docker compose -f ../inventory/docker-compose-db.yml up -d
sleep 10

echo "✅ Step 6: Starting Control Center (control-center)..."
docker compose -f ../inventory/docker-compose-c3.yml up -d
sleep 5

echo "🎉 All services started successfully!"
docker ps -a