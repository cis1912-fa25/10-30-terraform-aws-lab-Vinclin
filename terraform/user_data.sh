#!/bin/bash
# Configure the EC2 instance to pull and run the webapp container on boot
set -o errexit
set -o nounset
set -o pipefail

ECR_REPOSITORY_URL="${ecr_repository_url}"
REGION="us-east-1"
CONTAINER_NAME="webapp"

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

dnf install -y awscli docker

systemctl enable docker
systemctl start docker

aws ecr get-login-password --region "$${REGION}" | docker login --username AWS --password-stdin "$${ECR_REPOSITORY_URL}"

docker pull "$${ECR_REPOSITORY_URL}:latest"

if docker ps --all --format "{{.Names}}" | grep -q "^$${CONTAINER_NAME}$"; then
  docker rm --force "$${CONTAINER_NAME}"
fi

docker run -d \
  --name "$${CONTAINER_NAME}" \
  --restart unless-stopped \
  -p 80:80 \
  "$${ECR_REPOSITORY_URL}:latest"
