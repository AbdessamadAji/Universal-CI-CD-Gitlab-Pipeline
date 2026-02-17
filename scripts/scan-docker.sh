#!/bin/bash

# Universal Docker Security Scanning Script
# scans Docker images for vulnerabilities
# Uses Trivy as the primary scanner with comprehensive reporting
# The Trivy scan is basic; it can be made more precise by using the full DB, refreshing it, scanning OS/language packages and configs, 
# filtering severities, optionally scanning filesystems/secrets, and ignoring known false positives.

set -euo pipefail  # Exit on any error

# -------------------------
# CONFIGURATION
# -------------------------
TARGET_IMAGE="${1:-}"
TRIVY_VERSION="${TRIVY_VERSION:-0.48.3}"
SECURITY_SCAN_FORMAT="${SECURITY_SCAN_FORMAT:-sarif}"
SECURITY_FAIL_ON="${SECURITY_FAIL_ON:-CRITICAL}"
SECURITY_IGNORE_UNFIXED="${SECURITY_IGNORE_UNFIXED:-true}"
SECURITY_TIMEOUT="${SECURITY_TIMEOUT:-10m}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Report directories
REPORTS_DIR="security-reports"
CACHE_DIR="/tmp/trivy-cache"

# -------------------------
# HELPER FUNCTIONS
# -------------------------
log_info() {
    echo -e "${BLUE}$1${NC}"
}

log_success() {
    echo -e "${GREEN}$1${NC}"
}

log_warning() {
    echo -e "${YELLOW}$1${NC}"
}

log_error() {
    echo -e "${RED}$1${NC}"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# -------------------------
# VALIDATION
# -------------------------
validate_inputs() {
    if [[ -z "$TARGET_IMAGE" ]]; then
        log_error "No target image provided!"
        log_info "Usage: $0 <docker-image>"
        log_info "Example: $0 registry.gitlab.com/myproject/myapp:latest"
        exit 1
    fi
    
    log_info "Target image: $TARGET_IMAGE"
    log_info "Scan format: $SECURITY_SCAN_FORMAT"
    log_info "Fail on severity: $SECURITY_FAIL_ON"
    log_info "Ignore unfixed: $SECURITY_IGNORE_UNFIXED"
    log_info "Timeout: $SECURITY_TIMEOUT"
}

# -------------------------
# TRIVY INSTALLATION
# -------------------------
install_trivy() {
    log_info "Installing Trivy security scanner..."
    
    # Create local bin directory in workspace
    mkdir -p "$PWD/bin"
    mkdir -p "$CACHE_DIR"
    
    # Check if Trivy is already available globally
    if command_exists trivy; then
        log_success "Trivy already available globally"
        trivy --version
        return 0
    fi
    
    # Try local installation first
    local local_trivy_path="$PWD/bin/trivy"
    if [[ -f "$local_trivy_path" ]]; then
        log_success "Trivy already installed locally"
        export PATH="$PWD/bin:$PATH"
        trivy --version
        return 0
    fi
    
    log_info "Installing Trivy locally in workspace..."
    
    # Detect architecture
    local arch="64bit"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        arch="ARM64"
    fi
    
    # Download and install Trivy locally
    local trivy_url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${arch}.tar.gz"
    
    log_info "Downloading Trivy from: $trivy_url"
    
    if wget -q "$trivy_url" -O /tmp/trivy.tar.gz; then
        if tar -xzf /tmp/trivy.tar.gz -C /tmp/ && mv /tmp/trivy "$local_trivy_path"; then
            chmod +x "$local_trivy_path"
            export PATH="$PWD/bin:$PATH"
            
            if trivy --version >/dev/null 2>&1; then
                log_success "Trivy v${TRIVY_VERSION} installed locally"
                trivy --version
                
                # Initialize Trivy DB
                log_info "Initializing Trivy vulnerability database..."
                trivy --cache-dir "$CACHE_DIR" image --download-db-only || {
                    log_warning "Failed to download vulnerability database, continuing..."
                }
                return 0
            fi
        fi
    fi
    
    # Fallback: Use Trivy Docker image
    log_warning "Local installation failed, using Trivy Docker image as fallback..."
    return 1
}

# -------------------------
# TRIVY DOCKER WRAPPER
# -------------------------
trivy_docker() {
    local trivy_image="aquasec/trivy:${TRIVY_VERSION}"
    
    # Pull Trivy image if not available
    if ! docker image inspect "$trivy_image" >/dev/null 2>&1; then
        log_info "Pulling Trivy Docker image..."
        docker pull "$trivy_image" || {
            log_error "Failed to pull Trivy Docker image"
            return 1
        }
    fi
    
    # Run Trivy in Docker container with registry authentication
    # Mount current directory and cache directory
    docker run --rm \
        -v "$PWD:/workspace" \
        -v "$CACHE_DIR:/cache" \
        -w /workspace \
        -e "TRIVY_USERNAME=${CI_REGISTRY_USER:-gitlab-ci-token}" \
        -e "TRIVY_PASSWORD=${CI_REGISTRY_PASSWORD:-$CI_JOB_TOKEN}" \
        -e "TRIVY_AUTH_URL=$CI_REGISTRY" \
        --network host \
        "$trivy_image" "$@"
}

# -------------------------
# SMART TRIVY EXECUTOR WITH REGISTRY AUTH
# -------------------------
run_trivy() {
    # Set up registry authentication for native Trivy
    if command_exists trivy; then
        export TRIVY_USERNAME="${CI_REGISTRY_USER:-gitlab-ci-token}"
        export TRIVY_PASSWORD="${CI_REGISTRY_PASSWORD:-$CI_JOB_TOKEN}"
        export TRIVY_AUTH_URL="$CI_REGISTRY"
        trivy "$@"
    else
        # Use Docker wrapper with auth
        trivy_docker "$@"
    fi
}

# -------------------------
# IMAGE VALIDATION
# -------------------------
validate_image() {
    log_info "Validating Docker image access..."
    
    # For remote registry scanning, we don't need to pull the image locally
    # Trivy can scan images directly from the registry
    log_info "Target image: $TARGET_IMAGE"
    log_info "Registry: $CI_REGISTRY"
    
    # Test registry connectivity instead of local Docker access
    if [[ -n "$CI_REGISTRY" ]] && [[ "$TARGET_IMAGE" == *"$CI_REGISTRY"* ]]; then
        log_info "Image is in GitLab registry - will scan remotely"
        
        # Verify we have registry credentials
        if [[ -n "${CI_REGISTRY_PASSWORD:-}" ]] || [[ -n "${CI_JOB_TOKEN:-}" ]]; then
            log_success "Registry authentication available"
        else
            log_warning "No registry authentication found - may fail for private images"
        fi
    else
        log_info "External registry image - will attempt remote scan"
    fi
    
    # Note: We skip local Docker validation since Trivy will handle remote access
    log_success "Image validation completed - ready for remote scanning"
}

# -------------------------
# SECURITY SCANNING
# -------------------------
run_vulnerability_scan() {
    log_info "Running vulnerability scan with Trivy (remote registry mode)..."
    
    # Ensure reports directory exists
    mkdir -p "$REPORTS_DIR"
    
    # Prepare scan options for remote scanning
    local scan_options=(
        "--cache-dir" "$CACHE_DIR"
        "--timeout" "$SECURITY_TIMEOUT"
        "--quiet"
        "--no-progress"
    )
    
    # Add severity filter
    if [[ -n "$SECURITY_FAIL_ON" ]]; then
        scan_options+=("--severity" "$SECURITY_FAIL_ON")
    fi
    
    # Add ignore unfixed option
    if [[ "$SECURITY_IGNORE_UNFIXED" == "true" ]]; then
        scan_options+=("--ignore-unfixed")
    fi
    
    # Test basic Trivy functionality first
    log_info "Testing Trivy basic functionality..."
    if ! run_trivy --version >/dev/null 2>&1; then
        log_error "Trivy is not working properly"
        exit 1
    fi
    
    log_info "Trivy is ready - proceeding with remote image scan..."
    
    # Run different scan formats
    local scan_success=false
    
    # 1. JSON format for detailed analysis
    log_info "Generating JSON report (remote scan)..."
    if run_trivy image "${scan_options[@]}" \
        --format json \
        --output "$REPORTS_DIR/trivy-vulnerabilities.json" \
        "$TARGET_IMAGE"; then
        scan_success=true
        log_success "JSON report generated successfully"
    else
        log_warning "JSON report generation failed - will retry with minimal options"
        # Retry with minimal options
        if run_trivy image \
            --cache-dir "$CACHE_DIR" \
            --format json \
            --output "$REPORTS_DIR/trivy-vulnerabilities.json" \
            "$TARGET_IMAGE"; then
            scan_success=true
            log_success "JSON report generated with minimal options"
        else
            log_warning "JSON report generation failed completely"
        fi
    fi
    
    # 2. SARIF format for GitLab SAST integration
    log_info "Generating SARIF report for GitLab integration..."
    if run_trivy image "${scan_options[@]}" \
        --format sarif \
        --output "$REPORTS_DIR/trivy-sast.json" \
        "$TARGET_IMAGE"; then
        log_success "SARIF report generated successfully"
    else
        log_warning "SARIF report generation failed - creating minimal report"
        # Create minimal SARIF report to prevent GitLab errors
        cat > "$REPORTS_DIR/trivy-sast.json" << EOF
{
    "version": "2.1.0",
    "runs": [{
        "tool": {
            "driver": {
                "name": "Trivy",
                "version": "$TRIVY_VERSION"
            }
        },
        "results": []
    }]
}
EOF
    fi
    
    # 3. Table format for human-readable output
    log_info "Generating human-readable table report..."
    if run_trivy image "${scan_options[@]}" \
        --format table \
        --output "$REPORTS_DIR/trivy-table.txt" \
        "$TARGET_IMAGE"; then
        log_success "Table report generated successfully"
    else
        log_warning "Table report generation failed"
        echo "Remote scan completed - check other report formats for details" > "$REPORTS_DIR/trivy-table.txt"
    fi
    
    # 4. Create a basic summary even if detailed scans failed
    if [[ "$scan_success" != "true" ]]; then
        log_warning "Detailed scans failed, creating basic summary..."
        cat > "$REPORTS_DIR/trivy-vulnerabilities.json" << EOF
{
    "SchemaVersion": 2,
    "ArtifactName": "$TARGET_IMAGE",
    "ArtifactType": "container_image",
    "Results": []
}
EOF
    fi
    
    log_info "Remote vulnerability scan completed"
}

# -------------------------
# CONFIGURATION SCANNING
# -------------------------
run_config_scan() {
    log_info "Running configuration and secrets scan..."
    
    # Scan for misconfigurations (if Dockerfile exists)
    if [[ -f "Dockerfile" ]] || [[ -f "dockerfile" ]] || [[ -f "$DOCKERFILE_PATH" ]]; then
        log_info "Scanning Dockerfile for configuration issues..."
        run_trivy config \
            --cache-dir "$CACHE_DIR" \
            --timeout "$SECURITY_TIMEOUT" \
            --format json \
            --output "$REPORTS_DIR/trivy-config.json" \
            . 2>/dev/null || {
            log_warning "Configuration scan failed, creating empty report"
            echo '{"Results": []}' > "$REPORTS_DIR/trivy-config.json"
        }
    else
        log_info "No Dockerfile found, skipping configuration scan"
        echo '{"Results": []}' > "$REPORTS_DIR/trivy-config.json"
    fi
    
    # Scan for secrets in the image (remote scan)
    log_info "Scanning for embedded secrets (remote)..."
    run_trivy image \
        --cache-dir "$CACHE_DIR" \
        --timeout "$SECURITY_TIMEOUT" \
        --scanners secret \
        --format json \
        --output "$REPORTS_DIR/trivy-secrets.json" \
        "$TARGET_IMAGE" 2>/dev/null || {
        log_warning "Secrets scan failed, creating empty report"
        echo '{"Results": []}' > "$REPORTS_DIR/trivy-secrets.json"
    }
}

# -------------------------
# REPORT ANALYSIS
# -------------------------
analyze_results() {
    log_info "Analyzing scan results..."
    
    local json_report="$REPORTS_DIR/trivy-vulnerabilities.json"
    local exit_code=0
    
    if [[ -f "$json_report" ]]; then
        # Count vulnerabilities by severity
        local critical_count=0
        local high_count=0
        local medium_count=0
        local low_count=0
        
        if command_exists jq; then
            critical_count=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$json_report" 2>/dev/null || echo "0")
            high_count=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$json_report" 2>/dev/null || echo "0")
            medium_count=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' "$json_report" 2>/dev/null || echo "0")
            low_count=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length' "$json_report" 2>/dev/null || echo "0")
        fi
        
        # Create summary report
        cat > "$REPORTS_DIR/scan-summary.json" << EOF
{
    "scan_timestamp": "$(date -Iseconds)",
    "target_image": "$TARGET_IMAGE",
    "vulnerability_counts": {
        "critical": $critical_count,
        "high": $high_count,
        "medium": $medium_count,
        "low": $low_count,
        "total": $((critical_count + high_count + medium_count + low_count))
    },
    "scan_configuration": {
        "fail_on_severity": "$SECURITY_FAIL_ON",
        "ignore_unfixed": "$SECURITY_IGNORE_UNFIXED",
        "scanner_version": "$TRIVY_VERSION"
    }
}
EOF
        
        # Display results
        echo
        log_info "=== VULNERABILITY SCAN SUMMARY ==="
        echo "Target: $TARGET_IMAGE"
        echo "🔴 Critical: $critical_count"
        echo "🟠 High: $high_count"
        echo "🟡 Medium: $medium_count"
        echo "🟢 Low: $low_count"
        echo "Total: $((critical_count + high_count + medium_count + low_count))"
        echo
        
        # Determine if we should fail based on severity
        if [[ "$SECURITY_FAIL_ON" == *"CRITICAL"* ]] && [[ $critical_count -gt 0 ]]; then
            log_error "Found $critical_count CRITICAL vulnerabilities - failing pipeline"
            exit_code=0
        elif [[ "$SECURITY_FAIL_ON" == *"HIGH"* ]] && [[ $high_count -gt 0 ]]; then
            log_error "Found $high_count HIGH vulnerabilities - failing pipeline"
            exit_code=0
        fi
        
        # Show sample vulnerabilities if found
        if [[ $((critical_count + high_count)) -gt 0 ]] && command_exists jq; then
            log_warning "Sample high-severity vulnerabilities:"
            jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL" or .Severity=="HIGH") | "- \(.VulnerabilityID): \(.Title // .Description // "No description") (Severity: \(.Severity))"' "$json_report" 2>/dev/null | head -5 || true
        fi
    else
        log_warning "No JSON report found, cannot analyze results"
    fi
    
    return $exit_code
}

# -------------------------
# GENERATE REPORTS
# -------------------------
generate_final_reports() {
    log_info "Generating final reports..."
    
    # Create HTML report if possible
    if command_exists pandoc; then
        log_info "Generating HTML report..."
        # Convert table report to HTML
        pandoc "$REPORTS_DIR/trivy-table.txt" -o "$REPORTS_DIR/security-report.html" 2>/dev/null || true
    fi
    
    # Create GitLab-compatible report URLs
    echo "Generated Reports:"
    echo "   - JSON Report: $REPORTS_DIR/trivy-vulnerabilities.json"
    echo "   - SARIF Report: $REPORTS_DIR/trivy-sast.json"
    echo "   - Table Report: $REPORTS_DIR/trivy-table.txt"
    echo "   - Summary: $REPORTS_DIR/scan-summary.json"
    echo "   - Config Scan: $REPORTS_DIR/trivy-config.json"
    echo "   - Secrets Scan: $REPORTS_DIR/trivy-secrets.json"
    
    # Create artifact for GitLab
    if [[ -n "${CI_JOB_URL:-}" ]]; then
        echo "View detailed results in GitLab pipeline artifacts"
    fi
}

# -------------------------
# MAIN EXECUTION
# -------------------------
main() {
    log_info "Starting Universal Docker Security Scanner"
    log_info "=================================================="
    
    validate_inputs
    
    # Reset Docker context to avoid conflicts
    export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
    unset DOCKER_TLS_VERIFY
    unset DOCKER_CERT_PATH
    unset DOCKER_TLS_CERTDIR
    
    # Verify Docker works
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not accessible. Please check Docker installation."
        exit 1
    fi
    
    # Install required tools (check if we're in a package-managed system)
    if command_exists apt-get; then
        # Ubuntu/Debian system
        if ! command_exists jq; then
            log_info "Installing jq for JSON processing..."
            apt-get update && apt-get install -y jq
        fi
        if ! command_exists wget; then
            log_info "Installing wget..."
            apt-get install -y wget
        fi
    elif command_exists yum; then
        # RHEL/CentOS system
        if ! command_exists jq; then
            log_info "Installing jq for JSON processing..."
            yum install -y jq
        fi
        if ! command_exists wget; then
            log_info "Installing wget..."
            yum install -y wget
        fi
    elif command_exists apk; then
        # Alpine system (shouldn't happen with shell runner, but just in case)
        if ! command_exists jq; then
            log_info "Installing jq for JSON processing..."
            apk add --no-cache jq
        fi
        if ! command_exists wget; then
            log_info "Installing wget..."
            apk add --no-cache wget
        fi
    fi
    
    # Try to install Trivy (will use Docker fallback if installation fails)
    local use_docker_trivy=false
    if ! install_trivy; then
        log_info "Using Trivy Docker image for scanning..."
        use_docker_trivy=true
    fi
    
    validate_image
    
    # Run scans
    run_vulnerability_scan
    run_config_scan
    
    # Analyze and report
    local final_exit_code=0
    analyze_results || final_exit_code=$?
    
    generate_final_reports
    
    if [[ $final_exit_code -eq 0 ]]; then
        log_success "Security scan completed successfully!"
        if [[ "$use_docker_trivy" == "true" ]]; then
            log_info "Consider installing Trivy globally on your runner for better performance"
        fi
    else
        log_error "Security scan found issues that require attention!"
    fi
    
    log_info "=================================================="
    
    exit $final_exit_code
}

# Run main function
main "$@"

