#!/bin/bash

#set -e

# Variables (will be set in .gitlab-ci.yml)
URL="simo6king.duckdns.org"        # e.g., example.com
APP_NAME="site"   # e.g., myapp
APP_PORT="8080"   # e.g., 3000
EMAIL="abdessamadajiemail@gmail.com"      # e.g., your-email@example.com

# Install Nginx and Certbot
install_packages() {
    if id=$(grep ^ID= /etc/os-release 2>/dev/null | cut -d= -f2); then
        id="${id//\"/}"
        case "$id" in
            ubuntu|debian)
                if command -v apt &> /dev/null; then
                    apt update && apt upgrade -y
                    apt install -y nginx certbot python3-certbot-nginx
                    systemctl start nginx
                    systemctl enable nginx
                    systemctl status nginx
                    certbot --version
                else
                    echo "Package manager apt not found"
                    return 1
                fi
                ;;
            centos|rhel|fedora)
                if command -v yum &> /dev/null; then
                    yum update -y
                    yum install -y epel-release nginx certbot python2-certbot-nginx
                    systemctl start nginx
                    systemctl enable nginx
                    systemctl status nginx
                    certbot --version
                elif command -v dnf &> /dev/null; then
                    dnf upgrade -y
                    dnf install -y nginx certbot python3-certbot-nginx
                    systemctl start nginx
                    systemctl enable nginx
                    systemctl status nginx
                    certbot --version
                else
                    echo "Package manager yum or dnf not found"
                    return 1
                fi
                ;;
            alpine)
                if command -v apk &> /dev/null; then
                    apk update
                    apk upgrade
                    apk add nginx certbot certbot-nginx
                    rc-service nginx start
                    rc-update add nginx
                    rc-service nginx status
                    certbot --version
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
    else
        echo "/etc/os-release not found. Cannot detect distribution."
        return 1
    fi
}

# Determine proper Nginx site config path
nginx_config_path() {
    if [ -d "/etc/nginx/sites-available" ]; then
        NGINX_CONFIG_FILE="/etc/nginx/sites-available/$APP_NAME.conf"
    elif [ -d "/etc/nginx/conf.d" ]; then
        NGINX_CONFIG_FILE="/etc/nginx/conf.d/$APP_NAME.conf"
    else
        echo "Nginx config path not found"
        return 1
    fi
    echo "Nginx config will be written to: $NGINX_CONFIG_FILE"
}

# Generate Nginx config
nginx_config() {
    echo "Writing Nginx config for HTTP..."
    cat > "$NGINX_CONFIG_FILE" <<EOF
server {
    listen 80;
    server_name $URL www.$URL;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    echo "Nginx HTTP config created!"
}

# Run Certbot automatically
run_certbot() {
    echo "Running Certbot to enable HTTPS..."
    certbot --nginx -d "$URL" -d "www.$URL" --non-interactive --agree-tos --redirect -m "$EMAIL"
    echo "HTTPS enabled with Certbot!"
}

# Enable site and reload Nginx
enable_and_reload_nginx() {
    if [ -d "/etc/nginx/sites-enabled" ]; then
        ln -sf "$NGINX_CONFIG_FILE" /etc/nginx/sites-enabled/
    fi
    nginx -t
    systemctl reload nginx
    echo "Nginx reloaded!"
}

# Main function
main() {
    install_packages
    nginx_config_path
    nginx_config
    enable_and_reload_nginx
    run_certbot
}

# Run main
main

