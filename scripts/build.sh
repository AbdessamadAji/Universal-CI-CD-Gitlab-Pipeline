#!/bin/bash
set -e

# A script dedicated for building any tech
# Created to resolve the java build issue

display() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

display "Starting the build script !"

PROJECT_TYPE=""
BUILD_EXIT_CODE=0

# Function to detect project type
detect_project_type() {
    if [[ -f ".deps/project_type" ]]; then
        PROJECT_TYPE=$(cat .deps/project_type)
        echo "Project type from cache: $PROJECT_TYPE"
    elif [[ -f "package.json" ]]; then
        PROJECT_TYPE="nodejs"
    elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]]; then
        PROJECT_TYPE="python"
    elif [[ -f "go.mod" ]]; then
        PROJECT_TYPE="go"
    elif [[ -f "Cargo.toml" ]]; then
        PROJECT_TYPE="rust"
    elif [[ -f "pom.xml" || -f "build.gradle" ]]; then
        PROJECT_TYPE="java"
    elif [[ -f "composer.json" ]]; then
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

# Run build based on project type
run_builds() {
    case $PROJECT_TYPE in
        "java")
            echo "Running Java build..."
            if command -v java > /dev/null 2>&1; then
    		if command -v mvn > /dev/null 2>&1; then
        		mvn clean package || BUILD_EXIT_CODE=$?
    		else
        		echo "⚠ Maven not found, installing..."
			export DEBIAN_FRONTEND=noninteractive
        		apt-get update -qq
			apt-get install -y -qq maven
        		mvn clean package || BUILD_EXIT_CODE=$?
    		fi
	     else
    		echo "⚠ Java not found, installing JDK + Maven..."
		export DEBIAN_FRONTEND=noninteractive
    		apt-get update -qq
		apt-get install -y -qq openjdk-17-jdk maven
    		mvn clean package || BUILD_EXIT_CODE=$?
	     fi
             ;;
        *)
            echo "$PROJECT_TYPE project: let Dockerfile handle build"
            ;;
    esac
}

main() {
    detect_project_type
    run_builds
    
    echo "Build summary:"
    echo "  - Type: $PROJECT_TYPE"
    echo "Build completed!"
    exit $BUILD_EXIT_CODE
}

main "$@"

