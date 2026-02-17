#!/bin/bash
set -e

# deploy.sh - Universal container deployment script
# Handles Docker registry login, container lifecycle, and health checks

echo "Starting container deployment..."

# Environment variables with defaults
APP_NAME=${APP_NAME:-"my-app"}
CONTAINER_NAME=${CONTAINER_NAME:-"${APP_NAME}-${CI_COMMIT_REF_SLUG:-"latest"}"}
HOST_PORT=${HOST_PORT:-"3000"}
CONTAINER_PORT=${CONTAINER_PORT:-"3000"}
HEALTH_CHECK_PATH=${HEALTH_CHECK_PATH:-"/"}
DOCKER_RESTART_POLICY=${DOCKER_RESTART_POLICY:-"unless-stopped"}
DOCKER_EXTRA_ARGS=${DOCKER_EXTRA_ARGS:-""}
IMAGE_TAG=${CI_REGISTRY_IMAGE:-"my-app"}:${IMAGE_TAG_REF:-"latest"}

# Configuration
MAX_HEALTH_CHECKS=6
HEALTH_CHECK_INTERVAL=10
PORT_RELEASE_WAIT=5

# Function to log with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to log section headers
log_section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Docker registry authentication
docker_login() {
    log_section "DOCKER REGISTRY LOGIN"
    
    if [[ -n "$CI_REGISTRY_PASSWORD" ]]; then
        log "Using CI_REGISTRY_PASSWORD for authentication"
        echo "$CI_REGISTRY_PASSWORD" | docker login -u "$CI_REGISTRY_USER" --password-stdin "$CI_REGISTRY"
    elif [[ -n "$CI_JOB_TOKEN" ]]; then
        log "Using CI_JOB_TOKEN for authentication"
        echo "$CI_JOB_TOKEN" | docker login -u gitlab-ci-token --password-stdin "$CI_REGISTRY"
    else
        log "No registry credentials found - assuming public image or already logged in"
    fi
}

# System status check
check_system_status() {
    log_section "SYSTEM STATUS CHECK"
    
    log "Docker version:"
    docker --version
    
    log "Available disk space:"
    df -h / | head -2
    
    log "Docker system info:"
    docker system df 2>/dev/null || log "Unable to get Docker system info"
}

# Port availability check
check_port_availability() {
    log_section "PORT AVAILABILITY CHECK"
    
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tlnp 2>/dev/null | grep ":$HOST_PORT " > /dev/null; then
            log "Port $HOST_PORT is currently in use:"
            netstat -tlnp 2>/dev/null | grep ":$HOST_PORT " || true
        else
            log "Port $HOST_PORT is available"
        fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep ":$HOST_PORT " > /dev/null; then
            log "Port $HOST_PORT is currently in use:"
            ss -tlnp 2>/dev/null | grep ":$HOST_PORT " || true
        else
            log "Port $HOST_PORT is available"
        fi
    else
        log "Unable to check port status (netstat/ss not available)"
    fi
}

# Pull the latest image
pull_image() {
    log_section "PULLING LATEST IMAGE"
    
    log "Pulling image: $IMAGE_TAG"
    
    if docker pull "$IMAGE_TAG"; then
        log "Image pulled successfully"
    else
        log "Failed to pull image: $IMAGE_TAG"
        exit 1
    fi
    
    log "Image details:"
    docker image inspect "$IMAGE_TAG" --format '{{.RepoTags}} {{.Created}} {{.Size}}' 2>/dev/null || true
}

# Stop and remove existing containers
cleanup_existing_containers() {
    log_section "CLEANUP EXISTING DEPLOYMENT"
    
    # Stop container by name
    if docker ps -q -f name="$CONTAINER_NAME" | grep -q .; then
        log "Stopping existing container: $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME" || true
        docker rm "$CONTAINER_NAME" || true
        log "Container $CONTAINER_NAME removed"
    else
        log "No existing container named $CONTAINER_NAME found"
    fi
    
    # Stop any container using the target port
    local port_containers
    port_containers=$(docker ps --format "{{.ID}} {{.Ports}}" | grep ":$HOST_PORT->" | cut -d' ' -f1 || true)
    
    if [[ -n "$port_containers" ]]; then
        log "Stopping containers using port $HOST_PORT:"
        echo "$port_containers" | while read -r container_id; do
            if [[ -n "$container_id" ]]; then
                log "  Stopping container: $container_id"
                docker stop "$container_id" || true
                docker rm "$container_id" || true
            fi
        done
    else
        log "No containers using port $HOST_PORT"
    fi
    
    log "Waiting ${PORT_RELEASE_WAIT}s for port to be released..."
    sleep "$PORT_RELEASE_WAIT"
}

# Start the new container
start_container() {
    log_section "STARTING NEW CONTAINER"
    
    log "Container configuration:"
    log "  Name: $CONTAINER_NAME"
    log "  Image: $IMAGE_TAG"
    log "  Port mapping: $HOST_PORT:$CONTAINER_PORT"
    log "  Restart policy: $DOCKER_RESTART_POLICY"
    log "  Extra args: $DOCKER_EXTRA_ARGS"
    
    local docker_cmd="docker run -d \
        --name $CONTAINER_NAME \
        --restart $DOCKER_RESTART_POLICY \
        -p $HOST_PORT:$CONTAINER_PORT"
    
    # Add extra arguments if provided
    if [[ -n "$DOCKER_EXTRA_ARGS" ]]; then
        docker_cmd="$docker_cmd $DOCKER_EXTRA_ARGS"
    fi
    
    docker_cmd="$docker_cmd $IMAGE_TAG"
    
    log "Executing: $docker_cmd"
    
    if eval "$docker_cmd"; then
        log "Container started successfully"
    else
        log "Failed to start container"
        exit 1
    fi
    
    log "Waiting for container to initialize..."
    sleep "$HEALTH_CHECK_INTERVAL"
}

# Health check function
perform_health_check() {
    log_section "HEALTH CHECK"
    
    local health_url="http://localhost:$HOST_PORT$HEALTH_CHECK_PATH"
    log "Health check URL: $health_url"
    
    for i in $(seq 1 "$MAX_HEALTH_CHECKS"); do
        log "Health check attempt $i/$MAX_HEALTH_CHECKS..."
        
        if curl -f -s --max-time 10 "$health_url" > /dev/null 2>&1; then
            log "Health check passed - application is ready"
            return 0
        else
            if [[ $i -eq $MAX_HEALTH_CHECKS ]]; then
                log "Health check failed after $MAX_HEALTH_CHECKS attempts"
                log "Container logs (last 50 lines):"
                docker logs --tail 50 "$CONTAINER_NAME" || true
                return 1
            else
                log "Health check failed, retrying in ${HEALTH_CHECK_INTERVAL}s..."
                sleep "$HEALTH_CHECK_INTERVAL"
            fi
        fi
    done
}

# Container status report
generate_status_report() {
    log_section "DEPLOYMENT STATUS"
    
    log "Container information:"
    docker ps -f name="$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" || true
    
    log "Container stats:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" "$CONTAINER_NAME" 2>/dev/null || log "Unable to get container stats"
    
    log "Recent container logs (last 10 lines):"
    docker logs --tail 10 "$CONTAINER_NAME" 2>/dev/null || log "Unable to get container logs"
}

# Create deployment artifacts
create_deployment_artifacts() {
    log_section "CREATING DEPLOYMENT ARTIFACTS"
    
    # Create deployment environment file
    cat > deploy.env << EOF
DEPLOYED_APP=$APP_NAME
DEPLOYED_CONTAINER=$CONTAINER_NAME
DEPLOYED_URL=http://localhost:$HOST_PORT
DEPLOYED_IMAGE=$IMAGE_TAG
DEPLOYMENT_TIME=$(date -Iseconds)
DEPLOYMENT_COMMIT=${CI_COMMIT_SHA:-"unknown"}
EOF
    
    # Create detailed deployment info JSON
    cat > deployment-info.json << EOF
{
  "deployment": {
    "timestamp": "$(date -Iseconds)",
    "app_name": "$APP_NAME",
    "container_name": "$CONTAINER_NAME",
    "image": "$IMAGE_TAG",
    "ports": {
      "host": "$HOST_PORT",
      "container": "$CONTAINER_PORT"
    },
    "urls": {
      "application": "http://localhost:$HOST_PORT",
      "health_check": "http://localhost:$HOST_PORT$HEALTH_CHECK_PATH"
    },
    "git": {
      "commit": "${CI_COMMIT_SHA:-"unknown"}",
      "branch": "${CI_COMMIT_REF_NAME:-"unknown"}",
      "short_sha": "${CI_COMMIT_SHORT_SHA:-"unknown"}"
    },
    "configuration": {
      "restart_policy": "$DOCKER_RESTART_POLICY",
      "extra_args": "$DOCKER_EXTRA_ARGS"
    }
  }
}
EOF
    
    log "Deployment artifacts created:"
    log "  - deploy.env"
    log "  - deployment-info.json"
}

# Final deployment summary
show_deployment_summary() {
    log_section " DEPLOYMENT COMPLETE"
    
    cat << EOF
┌─────────────────────────────────────────────────────────────────┐
│                     DEPLOYMENT SUMMARY                         │
├─────────────────────────────────────────────────────────────────┤
│ Application: $APP_NAME
│ Container:   $CONTAINER_NAME
│ URL:         http://localhost:$HOST_PORT
│ Image:       $IMAGE_TAG
│ Time:        $(date)
├─────────────────────────────────────────────────────────────────┤
│                    USEFUL COMMANDS                             │
├─────────────────────────────────────────────────────────────────┤
│ Check status:    docker ps -f name=$CONTAINER_NAME
│ View logs:       docker logs -f $CONTAINER_NAME
│ Enter container: docker exec -it $CONTAINER_NAME sh
│ Health check:   curl http://localhost:$HOST_PORT$HEALTH_CHECK_PATH
│ Stop container:  docker stop $CONTAINER_NAME
└─────────────────────────────────────────────────────────────────┘
EOF
}

# Main deployment function
main() {
    log "🚀 Starting deployment of $APP_NAME..."
    log "📋 Configuration check:"
    log "  - APP_NAME: $APP_NAME"
    log "  - CONTAINER_NAME: $CONTAINER_NAME" 
    log "  - IMAGE_TAG: $IMAGE_TAG"
    log "  - HOST_PORT: $HOST_PORT"
    log "  - CONTAINER_PORT: $CONTAINER_PORT"
    log "  - HEALTH_CHECK_PATH: $HEALTH_CHECK_PATH"
    
    # Pre-deployment checks and setup
    docker_login
    check_system_status
    check_port_availability
    
    # Pull and deploy
    pull_image
    cleanup_existing_containers
    start_container
    
    # Post-deployment verification
    if perform_health_check; then
        generate_status_report
        create_deployment_artifacts
        show_deployment_summary
        log "✅ Deployment completed successfully!"
        exit 0
    else
        log "❌ Deployment failed - health check unsuccessful"
        log "Container logs for debugging:"
        docker logs "$CONTAINER_NAME" || true
        create_failure_artifacts $LINENO
        exit 1
    fi
}

# Error handling - create basic artifacts even on failure
trap 'log "❌ Deployment script failed at line $LINENO"; create_failure_artifacts; exit 1' ERR

# Create failure artifacts for debugging
create_failure_artifacts() {
    log "📋 Creating failure artifacts for debugging..."
    
    cat > deploy.env << EOF
DEPLOYED_APP=$APP_NAME
DEPLOYED_CONTAINER=$CONTAINER_NAME
DEPLOYED_URL=http://localhost:$HOST_PORT
DEPLOYED_IMAGE=$IMAGE_TAG
DEPLOYMENT_TIME=$(date -Iseconds)
DEPLOYMENT_STATUS=failed
FAILURE_LINE=$1
EOF
    
    cat > deployment-info.json << EOF
{
  "deployment": {
    "timestamp": "$(date -Iseconds)",
    "status": "failed",
    "app_name": "$APP_NAME",
    "container_name": "$CONTAINER_NAME",
    "image": "$IMAGE_TAG",
    "error": "Deployment failed",
    "failure_line": "$1"
  }
}
EOF
    
    log "📋 Failure artifacts created for debugging"
}

# Execute main function
main "$@"

