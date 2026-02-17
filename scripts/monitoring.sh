#!/bin/bash

#set -e

# Universal script to install and configure Prometheus, Grafana, Node Exporter, and cAdvisor.
# Ensures all targets are active and properly monitored in Prometheus.
# Adding dashboards to Grafana must be done manually.


display() {
    echo "_________________________________________"
    echo "              $1"
    echo "_________________________________________"
}

# Function to detect OS and install Prometheus and Grafana locally
local_install() {
    # Get the OS distribution
    if id=$(grep ^ID= /etc/os-release 2>/dev/null | cut -d= -f2); then
        id="${id//\"/}"
        case "$id" in
            ubuntu|debian)
                if command -v apt &> /dev/null; then
                    apt update && apt upgrade -y
                    apt install -y prometheus grafana wget tar docker.io
                else
                    echo "Package manager apt not found"
                    return 1
                fi
                ;;
            centos|rhel|fedora)
                if command -v yum &> /dev/null; then
                    yum update -y
                    yum install -y prometheus grafana wget tar docker
                elif command -v dnf &> /dev/null; then
                    dnf upgrade -y
                    dnf install -y prometheus grafana wget tar docker
                else
                    echo "Package manager yum or dnf not found"
                    return 1
                fi
                ;;
            alpine)
                if command -v apk &> /dev/null; then
                    apk update && apk upgrade
                    apk add prometheus grafana wget tar docker
                else
                    echo "Package manager apk not found"
                    return 1
                fi
                ;;
            *)
                echo "Unknown distribution: $id"
                return 1
                ;;
        esac

        # --- Install Node Exporter ---
        NODE_EXPORTER_VERSION="1.8.2"  # Use stable version
        NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
        
        if [ ! -f "/usr/local/bin/node_exporter" ]; then
            wget "$NODE_EXPORTER_URL"
            tar xvf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
            cd "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" || exit
            mv node_exporter /usr/local/bin/
            chmod +x /usr/local/bin/node_exporter
            cd ..
            rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"*
        fi

        # Create node_exporter systemd service
        if [ ! -f "/etc/systemd/system/node_exporter.service" ]; then
            tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=nobody
Group=nobody
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF
        fi

        systemctl daemon-reload
        systemctl start node_exporter
        systemctl enable node_exporter

        # --- Install cAdvisor ---
        CADVISOR_VERSION="0.49.1"  # Use stable version
        CADVISOR_URL="https://github.com/google/cadvisor/releases/download/v${CADVISOR_VERSION}/cadvisor-v${CADVISOR_VERSION}-linux-amd64"
        
        if [ ! -f "/usr/local/bin/cadvisor" ]; then
            wget "$CADVISOR_URL" -O cadvisor
            mv cadvisor /usr/local/bin/cadvisor
            chmod +x /usr/local/bin/cadvisor
        fi

        # Create cadvisor systemd service
        if [ ! -f "/etc/systemd/system/cadvisor.service" ]; then
            tee /etc/systemd/system/cadvisor.service > /dev/null <<EOF
[Unit]
Description=cAdvisor
After=network.target docker.service
Requires=docker.service

[Service]
User=root
ExecStart=/usr/local/bin/cadvisor -port=8080
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        fi

        systemctl daemon-reload
        systemctl start cadvisor
        systemctl enable cadvisor

        # Start and enable services
        systemctl start prometheus grafana-server docker
        systemctl enable prometheus grafana-server docker

        # Check service status
        echo "Checking service status..."
        for service in prometheus grafana-server node_exporter cadvisor docker; do
            if systemctl is-active --quiet "$service"; then
                echo "$service is running"
            else
                echo "$service is not running"
            fi
        done

    else
        echo "Failed to detect OS"
        return 1
    fi
}

# Function to install monitoring containers
container_install() {
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        echo "Docker is not running. Starting Docker..."
        systemctl start docker || service docker start || {
            echo "Failed to start Docker"
            return 1
        }
    fi

    # Create Docker network for monitoring
    if ! docker network ls | grep -q "monitoring"; then
        docker network create monitoring
    fi

    # Prometheus
    docker pull prom/prometheus:latest
     if [ "$(docker ps -aq -f name=^my_prometheus$)" ]; then
        echo "Prometheus container my_prometheus already exists. Deleting it..."
        docker stop my_prometheus >/dev/null 2>&1 || true
        docker rm my_prometheus >/dev/null 2>&1 || true
    fi
        echo "Prometheus container doesn't exist, running a new one..."
        # Create prometheus config directory
        mkdir -p /tmp/prometheus
        cat > /tmp/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF
        docker run -d --name my_prometheus \
            --network monitoring \
            -p 9090:9090 \
            -v /tmp/prometheus:/etc/prometheus \
            prom/prometheus:latest
    

    # Wait for Prometheus to be ready
    echo "Waiting for Prometheus to be ready..."
    for i in {1..30}; do
        if curl -s http://localhost:9090/-/ready | grep -q "Prometheus Server is Ready."; then
            echo "Prometheus is running!"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "Prometheus not ready after 30 attempts!"
            return 1
        fi
        sleep 2
    done

    # Grafana
    docker pull grafana/grafana:latest
    if [ "$(docker ps -aq -f name=^my_grafana$)" ]; then
        echo "Grafana container my_grafana already exists."
        if [ "$(docker ps -q -f name=^my_grafana$)" ]; then
            echo "Grafana container is already running. Nothing to do."
        else
            echo "Grafana container exists but is stopped. Starting it..."
            docker start my_grafana
        fi
    else
        echo "Grafana container doesn't exist, running a new one..."
        docker run -d --name my_grafana \
            --network monitoring \
            -p 3000:3000 \
            -e GF_SECURITY_ADMIN_PASSWORD=admin \
            grafana/grafana:latest
    fi

    # Wait for Grafana to be ready
    echo "Waiting for Grafana to be ready..."
    for i in {1..30}; do
        if curl -s http://localhost:3000/api/health | jq -e '.database=="ok"' > /dev/null; then
            echo "Grafana is working (admin/admin)"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "Grafana not ready after 30 attempts!"
        fi
        sleep 2
    done

    # Node Exporter
    docker pull prom/node-exporter:latest
    if [ "$(docker ps -aq -f name=^my_node_exporter$)" ]; then
        echo "Node-exporter container already exists."	
        if [ "$(docker ps -q -f name=^my_node_exporter$)" ]; then
            echo "Node-exporter container is already running. Nothing to do."
        else
            echo "Node-exporter container exists but is stopped. Starting it..."
            docker start my_node_exporter
        fi
    else
        echo "Node-exporter container doesn't exist, running a new one..."
        docker run -d --name my_node_exporter \
            --network monitoring \
            -p 9100:9100 \
            prom/node-exporter:latest
    fi

    # Wait for Node Exporter to be ready
    echo "Waiting for Node Exporter to be ready..."
    for i in {1..15}; do
        if curl -s http://localhost:9100/metrics | grep -q "node_cpu_seconds_total"; then
            echo "Node exporter is working"
            break
        fi
        if [ $i -eq 15 ]; then
            echo "Node exporter not ready!"
        fi
        sleep 2
    done

    # cAdvisor
    docker pull gcr.io/cadvisor/cadvisor:latest
    if [ "$(docker ps -aq -f name=^my_cadvisor$)" ]; then
        echo "cAdvisor container already exists."
        if [ "$(docker ps -q -f name=^my_cadvisor$)" ]; then
            echo "cAdvisor container is already running. Nothing to do."
        else
            echo "cAdvisor container exists but is stopped. Starting it..."
            docker start my_cadvisor
        fi
    else
        echo "cAdvisor container doesn't exist, running a new one..."
        docker run -d --name my_cadvisor \
            --network monitoring \
            --volume=/:/rootfs:ro \
            --volume=/var/run:/var/run:ro \
            --volume=/sys:/sys:ro \
            --volume=/var/lib/docker/:/var/lib/docker:ro \
            --volume=/dev/disk/:/dev/disk:ro \
            --privileged \
            --device=/dev/kmsg \
            -p 8080:8080 \
            gcr.io/cadvisor/cadvisor:latest
    fi

    # Wait for cAdvisor to be ready
    echo "Waiting for cAdvisor to be ready..."
    for i in {1..15}; do
        if curl -s http://localhost:8080/metrics | grep -q "container_cpu_usage_seconds_total"; then
            echo "cAdvisor exporter is working"
            break
        fi
        if [ $i -eq 15 ]; then
            echo "❌ cAdvisor exporter not ready!"
        fi
        sleep 2
    done
}

check_mode() {
    display "Checking if Docker is available"

    if command -v docker &> /dev/null; then
        display "Docker found"
        echo "Installing Prometheus and Grafana in Docker container"

        # Try to install in container; if it fails, fallback to local
        if ! container_install; then
            local_install
        fi

    else
        echo "Docker not found"
        
    fi
}


# Auto-discover Docker containers for monitoring
auto_discover_docker() {
    # Check if Docker exists
    if ! command -v docker &> /dev/null; then
        echo "Docker not found. Exiting."
        return 1
    fi

    # Find Prometheus container
    PROM_CON=$(docker ps --filter "name=my_prometheus" --format "{{.ID}}" | head -n 1)
    if [ -z "$PROM_CON" ]; then
        echo "Prometheus container not found."
        return 1
    fi

    # Get Prometheus config
    PROM_CONFIG_FILE="/tmp/prometheus/prometheus.yml"
    if [ ! -f "$PROM_CONFIG_FILE" ]; then
        docker cp "$PROM_CON:/etc/prometheus/prometheus.yml" "$PROM_CONFIG_FILE"
    fi

    # Create backup
    cp "$PROM_CONFIG_FILE" "${PROM_CONFIG_FILE}.backup"

    # Add monitoring services if not present
    add_monitoring_job() {
        local job_name="$1"
        local targets="$2"
        
        if ! grep -q "job_name: '$job_name'" "$PROM_CONFIG_FILE"; then
            cat <<EOL >> "$PROM_CONFIG_FILE"

  - job_name: '$job_name'
    static_configs:
      - targets: $targets
EOL
            echo "Added $job_name job to Prometheus config"
        fi
    }

    add_monitoring_job "grafana" "['my_grafana:3000']"
    add_monitoring_job "node_exporter" "['my_node_exporter:9100']"
    add_monitoring_job "cadvisor" "['my_cadvisor:8080']"

    # Find app containers (exclude monitoring ones)
    APP_CONTAINERS=$(docker ps --format "{{.Names}}" | grep -Ev "^(my_prometheus|my_grafana|my_cadvisor|my_node_exporter)$")
    
    if [ -n "$APP_CONTAINERS" ]; then
        echo "Detected app containers: $APP_CONTAINERS"
        
        # Build targets for app containers
        TARGETS=""
        for container in $APP_CONTAINERS; do
            # Get container network info
            NETWORK=$(docker inspect "$container" --format '{{range $net,$v := .NetworkSettings.Networks}}{{$net}}{{end}}' | head -1)
            
            # Try to get exposed ports
            PORTS=$(docker inspect "$container" --format '{{range $p,$v := .Config.ExposedPorts}}{{$p}} {{end}}')
            
            if [ -n "$PORTS" ]; then
                for port in $PORTS; do
                    port_num=$(echo "$port" | cut -d'/' -f1)
                    TARGETS="${TARGETS}      - '${container}:${port_num}'\n"
                    break  # Take first port
                done
            else
                echo "No exposed ports found for $container, skipping..."
            fi
        done
        
        if [ -n "$TARGETS" ]; then
            # Remove existing my_apps job if present
            if grep -q "job_name: 'my_apps'" "$PROM_CONFIG_FILE"; then
                sed -i "/- job_name: 'my_apps'/,/^  - job_name:/{ /^  - job_name: 'my_apps'/d; /^  - job_name:/!d; }" "$PROM_CONFIG_FILE"
            fi
            
            # Add new my_apps job
            cat <<EOL >> "$PROM_CONFIG_FILE"

  - job_name: 'my_apps'
    static_configs:
$(echo -e "$TARGETS" | sed 's/^/    /')
EOL
            echo "Added my_apps job with discovered containers"
        fi
    else
        echo "No application containers detected"
    fi

    # Copy config back to container and reload
    docker cp "$PROM_CONFIG_FILE" "$PROM_CON:/etc/prometheus/prometheus.yml"
    
    # Reload Prometheus configuration
    if docker kill -s HUP "$PROM_CON" 2>/dev/null; then
        echo "Prometheus configuration reloaded"
    else
        echo "Failed to reload Prometheus, restarting container..."
        docker restart "$PROM_CON"
    fi
}

auto_discover_local() {
    # Check if all services are running locally
    if ! (command -v prometheus &> /dev/null && \
          command -v grafana-server &> /dev/null && \
          pgrep -f node_exporter &> /dev/null && \
          pgrep -f cadvisor &> /dev/null && \
          command -v docker &> /dev/null); then
        echo "Not all required services are running locally"
        return 1
    fi

    # Find prometheus.yml file
    COMMON_PATHS=(
        "/etc/prometheus/prometheus.yml"
        "/usr/local/etc/prometheus.yml"
        "/opt/prometheus/prometheus.yml"
        "/etc/prometheus/prometheus.yaml"
    )
    
    PROM_PATH=""
    for path in "${COMMON_PATHS[@]}"; do
        if [ -f "$path" ]; then
            PROM_PATH="$path"
            break
        fi
    done

    # Fallback search
    if [ -z "$PROM_PATH" ]; then
        PROM_PATH=$(find /etc /usr/local /opt -name "prometheus.yml" -o -name "prometheus.yaml" 2>/dev/null | head -n 1)
    fi
    
    if [ -z "$PROM_PATH" ]; then
        echo "Prometheus config file not found"
        return 1
    fi
    
    echo "Using Prometheus config: $PROM_PATH"
    
    # Backup config
    cp "$PROM_PATH" "${PROM_PATH}.backup"

    # Function to get container IP dynamically
    get_container_ip() {
        local container_name="$1"
        docker inspect "$container_name" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1
    }

    # Function to check if container exists and is running
    container_running() {
        local container_name="$1"
        [ "$(docker ps -q -f name=^${container_name}$)" ]
    }

    # Create new prometheus configuration
    cat > "$PROM_PATH" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'grafana'
    static_configs:
      - targets: ['localhost:3000']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['localhost:8080']
EOF

    echo "Added local monitoring services"

    # Find Docker app containers and add them dynamically
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        APP_CONTAINERS=$(docker ps --format "{{.Names}}" | grep -Ev "^(my_prometheus|my_grafana|my_cadvisor|my_node_exporter)$")
        
        if [ -n "$APP_CONTAINERS" ]; then
            echo "🔍 Discovering application containers..."
            
            # Start my_apps job
            cat >> "$PROM_PATH" <<EOF

  - job_name: 'my_apps'
    static_configs:
      - targets: [
EOF
            
            FIRST_TARGET=true
            for container in $APP_CONTAINERS; do
                if container_running "$container"; then
                    CONTAINER_IP=$(get_container_ip "$container")
                    
                    if [ -n "$CONTAINER_IP" ]; then
                        # Try to detect the application port
                        APP_PORTS=$(docker inspect "$container" --format '{{range $p,$v := .Config.ExposedPorts}}{{$p}} {{end}}' | head -1)
                        
                        if [ -n "$APP_PORTS" ]; then
                            PORT_NUM=$(echo "$APP_PORTS" | cut -d'/' -f1)
                        else
                            # Check published ports
                            PORT_NUM=$(docker port "$container" 2>/dev/null | head -1 | cut -d':' -f2 | cut -d'-' -f1)
                            
                            # Common application ports fallback
                            if [ -z "$PORT_NUM" ]; then
                                for test_port in 8080 3000 8000 5000 8081; do
                                    if docker exec "$container" netstat -ln 2>/dev/null | grep -q ":$test_port "; then
                                        PORT_NUM="$test_port"
                                        break
                                    fi
                                done
                                [ -z "$PORT_NUM" ] && PORT_NUM="8080"
                            fi
                        fi
                        
                        # Add comma for subsequent targets
                        if [ "$FIRST_TARGET" = "false" ]; then
                            echo "," >> "$PROM_PATH"
                        fi
                        
                        # Add target without newline
                        printf "          '${CONTAINER_IP}:${PORT_NUM}'" >> "$PROM_PATH"
                        echo " Added app target: ${container} -> ${CONTAINER_IP}:${PORT_NUM}"
                        FIRST_TARGET=false
                    fi
                fi
            done
            
            # Close the targets array
            cat >> "$PROM_PATH" <<EOF

        ]
EOF
        fi
    fi

    # Reload Prometheus
    echo "Reloading Prometheus..."
    if command -v systemctl &> /dev/null; then
        systemctl reload prometheus || systemctl restart prometheus
        echo "Prometheus service reloaded"
    elif command -v service &> /dev/null; then
        service prometheus reload || service prometheus restart
        echo "Prometheus service reloaded"
    else
        PROM_PID=$(pgrep prometheus)
        if [ -n "$PROM_PID" ]; then
            kill -HUP "$PROM_PID"
            echo "Prometheus process reloaded via SIGHUP"
        fi
    fi
    
    echo ""
    echo "Access Prometheus targets at: http://localhost:9090/targets"
}

#send metrics to grafana

dashboards() {
    grafana_url="http://localhost:3000"
    user_pass="admin:admin"

    # Make sure the dashboards folder exists
    mkdir -p dashboards

    # Check if folder is empty and download dashboards if needed
    if [ -z "$(ls -A dashboards/)" ]; then
        echo "Folder is empty"
        echo "Downloading Node and Cadvisor exporters dashboards"

        wget -O dashboards/dashboard_cadvisor.json "https://grafana.com/api/dashboards/21743/revisions/3/download"
        wget -O dashboards/dashboard_node.json "https://grafana.com/api/dashboards/10242/revisions/1/download"
    fi

    # Add Prometheus datasource (if it doesn't exist, Grafana will create it)
    curl -s -u "$user_pass" -H "Content-Type: application/json" \
    -d '{
        "name": "Prometheus",
        "type": "prometheus",
        "url": "http://my_prometheus:9090",
        "access": "proxy",
        "isDefault": true
    }' "$grafana_url/api/datasources"


    # Set permissions
    chmod 777 dashboards/
    chmod 777 dashboards/*.json

    # Instructions for the user
    echo "Dashboards folder is ready"
    echo "Go to http://localhost:3000/dashboards"
    echo "Go to New → Create a new dashboard → Import dashboard → Upload JSON file."
    echo "Select the JSON file from ./dashboards/."
    echo "or simply enter ID : 21743 for cadvisor , and 10242 for Node "
    echo "Prometheus should be the datasource (it has been created automatically)."
    echo "Click Import."
}







# Main execution
main() {
    

    display "Starting Monitoring Setup"
    
    # Check and install monitoring stack
    check_mode
    
    echo
    display "Auto-discovering containers"
    
    # Auto-discover and configure monitoring targets
    if docker ps &> /dev/null 2>&1 && [ "$(docker ps -q -f name=my_prometheus)" ]; then
        auto_discover_docker
    else
        auto_discover_local
    fi
    
    echo
    display "Setup Complete"
    echo " Monitoring setup is complete!"
    echo
    echo "Access your monitoring services at:"
    echo "  Prometheus: http://localhost:9090"
    echo "  Grafana: http://localhost:3000 (admin/admin)"
    echo "  Node Exporter: http://localhost:9100"
    echo "  cAdvisor: http://localhost:8080"
    echo
	
	display "Preparing dashboards"
	dashboards
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

