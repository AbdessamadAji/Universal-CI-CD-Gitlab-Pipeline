#!/bin/bash
set -e


# See detect_project_type() when facing any issues with type detection
# install-deps.sh - Auto-detect project type and install dependencies automatically
# For Docker-based deployments, most dependencies are handled in Dockerfile

echo "Detecting project type..."

PROJECT_TYPE=""
DEPS_INSTALLED=false

#detect project type
detect_project_type() {
    if [[ -f "package.json" ]]; then
        PROJECT_TYPE="nodejs"
    elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]]; then
        PROJECT_TYPE="python"
    elif [[ -f "go.mod" ]]; then
        PROJECT_TYPE="go"
    elif [[ -f "Cargo.toml" ]]; then
        PROJECT_TYPE="rust"
    elif [[ -f "pom.xml" || -f "build.gradle" ]]; then
        PROJECT_TYPE="java"
    elif [[ -f "composer.json" ]] || compgen -G "*.php" > /dev/null; then
        PROJECT_TYPE="php"
    elif [[ -f "Gemfile" ]]; then
        PROJECT_TYPE="ruby"
    elif [[ -f "pubspec.yaml" ]]; then
        PROJECT_TYPE="dart"
    else
        PROJECT_TYPE="generic"
    fi
    
    echo "Detected project type: $PROJECT_TYPE"
}


# Install minimal system dependencies for CI
install_system_deps() {
    echo "Installing basic CI tools..."
    
    if command -v apk > /dev/null; then
        apk add --no-cache curl wget git || true
    elif command -v apt-get > /dev/null; then
        apt-get update && apt-get install -y curl wget git || true
    fi
}

# Create project info for other scripts
create_project_info() {
    mkdir -p .deps
    echo "$PROJECT_TYPE" > .deps/project_type
    echo "$(date)" > .deps/install_timestamp
    
    cat > .deps/project_info << EOF
PROJECT_TYPE=$PROJECT_TYPE
DEPS_HANDLED_IN_DOCKER=true
SETUP_TIMESTAMP=$(date -Iseconds)
EOF
}

# Main execution
main() {
    echo "Starting dependency setup..."
    
    detect_project_type
    install_system_deps
    create_project_info
    
    echo "Project summary:"
    echo "  - Type: $PROJECT_TYPE"
    echo "  - Dependencies: Handled in Docker build"
    echo "  - CI tools: Installed"
    echo "Setup complete - ready for testing and building!"
}

# Run main function
main "$@"

