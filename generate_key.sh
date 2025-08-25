# 2048 RSA 개인 키 생성

mkdir -p common/ssl

openssl genrsa -out common/ssl/tokenKeypair.pem 2048

# 공개 키 추출
openssl rsa \
  -in common/ssl/tokenKeypair.pem \
  -outform PEM \
  -pubout \
  -out common/ssl/public.pem
