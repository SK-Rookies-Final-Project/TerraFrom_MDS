# 디렉토리 환경 구성
mkdir ~/jdbc
cd ~/jdbc

# JDBC 드라이버 설치
wget https://downloads.mysql.com/archives/get/p/3/file/mysql-connector-j_8.4.0-1ubuntu24.04_all.deb

# .deb 패키지 설치
dpkg -x mysql-connector-j_8.4.0-1ubuntu24.04_all.deb ~/jdbc

# Container로 JDBC 드라이버 전송
docker cp ~/jdbc/usr/share/java/mysql-connector-j-8.4.0.jar kafka-connect1:/usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/lib/
docker cp ~/jdbc/usr/share/java/mysql-connector-j-8.4.0.jar kafka-connect2:/usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/lib/

# cw 컨테이너 재시작
docker restart kafka-connect1
docker restart kafka-connect2