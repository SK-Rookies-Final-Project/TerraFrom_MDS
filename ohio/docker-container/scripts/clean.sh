#!/bin/bash

echo "Docker 전체 정리 중..."

# 모든 컨테이너 중지 및 삭제
sh ./down.sh

# 모든 이미지 삭제
docker rmi -f $(docker images -q) 2>/dev/null

# 모든 볼륨 삭제
docker volume rm $(docker volume ls -q) 2>/dev/null

# 사용자 정의 네트워크 삭제
docker network rm $(docker network ls --filter type=custom -q) 2>/dev/null

# 시스템 정리
docker system prune -af --volumes >/dev/null 2>&1

echo "정리 완료"