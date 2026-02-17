#!/bin/bash
set -e  # Exit immediately if a command fails

# Not part of the pipeline
# Utility script to start a MySQL test container
# Run manually before the pipeline (not included in it)
# Edit as needed before use


# Check if container already exists
if [ "$(docker ps -aq -f name=mysql-db)" ]; then
    echo "MySQL container already exists. Removing..."
    docker rm -f mysql-db
fi

NETWORK_NAME="appnet"

# Check if the network exists
if ! docker network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME"; then
  echo "Creating network: $NETWORK_NAME"
  docker network create "$NETWORK_NAME"
else
  echo "Network '$NETWORK_NAME' already exists."
fi

# Create DB container
docker run -d \
  --name mysql-db \
  --network appnet \
  -e MYSQL_ROOT_PASSWORD=test \
  -e MYSQL_DATABASE=mydb \
  -e MYSQL_USER=test \
  -e MYSQL_PASSWORD=test \
  -v mysql-data:/var/lib/mysql \
  -p 3306:3306 \
  mysql:8.0

echo "Waiting for MySQL to be ready..."
until docker exec mysql-db mysqladmin ping -u test -ptest --silent; do
  echo "Waiting..."
  sleep 1
done

echo "Applying schema.sql..."
docker exec -i mysql-db mysql -u test -ptest mydb < ./schema.sql

echo "MySQL setup completed!"

