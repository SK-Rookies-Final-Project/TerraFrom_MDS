#!/bin/bash
mkdir -p ~/jdbc
cd ~/jdbc
# Kafka Connect 설정 파일 생성 스크립트

# JDBC MySQL Source 커넥터 설정 파일 생성
cat > jdbc-mysql-source.json << 'EOF'
{
    "name": "jdbc-mysql-source",
    "config": {
        "name": "jdbc-mysql-source",
        "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
        "connection.url": "jdbc:mysql://tgmysqldb.c1q6aqkoiwsl.us-east-2.rds.amazonaws.com:3306/tgmysqlDB",
        "connection.user": "tgadmin",
        "connection.password": "tgmaster!",
        "db.timezone": "Asia/Seoul",
        "tasks.max": "1",
        "table.whitelist": "user",
        "key.converter": "io.confluent.connect.avro.AvroConverter",
        "key.converter.schema.registry.url": "http://10.0.1.99:18081,http://10.0.1.99:18082",
        "value.converter": "io.confluent.connect.avro.AvroConverter",
        "value.converter.schema.registry.url": "http://10.0.1.99:18081,http://10.0.1.99:18082",
        "topic.creation.default.partitions": "1",
        "topic.creation.default.replication.factor": "3",
        "topic.prefix": "source-",
        "mode": "incrementing",
        "incrementing.column.name": "user_id",
        "transforms": "createKey",
        "transforms.createKey.type": "org.apache.kafka.connect.transforms.ValueToKey",
        "transforms.createKey.fields": "user_id"
    }
}
EOF

# JDBC PostgreSQL Sink 커넥터 설정 파일 생성
cat > jdbc-postgre-sink-test.json << 'EOF'
{
    "name": "jdbc-postgre-sink-test",
    "config": {
        "name": "jdbc-postgre-sink-test",
        "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
        "connection.url": "jdbc:postgresql://tgpostgresql.c1q6aqkoiwsl.us-east-2.rds.amazonaws.com:5432/tgpostgreDB",
        "connection.user": "tgadmin",
        "connection.password": "tgmaster!",
        "db.timezone": "Asia/Seoul",
        "tasks.max": "1",
        "insert.mode": "upsert",
        "pk.mode": "record_key",
        "pk.fields": "user_id",
        "table.name.format": "${topic}",
        "auto.create": "true",
        "auto.evolve": "true",
        "topics": "source-user"
    }
}
EOF
