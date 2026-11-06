#!/bin/sh
# POSIX-compliant shell script to deploy Apigee hybrid on GKE
# This script covers the initial setup of GCP infrastructure (GKE cluster),
# Apigee Management Plane (Org, Env, EnvGroup), and the initial Runtime Plane Operator.
# Note: Apigee hybrid uses Helm for component deployment.

### Important Notes:
### 0. Deployment script NOT to be used in production but for demo or experimentation (POC)
### 1. Verify the "default" VPC network and subnetwork in the target Google Cloud region exist
### 2. You may need to modify (Google Cloud) organization policies:
###    - constraints/iam.disableServiceAccountKeyCreation (must be set as Inactive)
###    - compute.vmExternalIpAccess (must be set as Inactive)
###    - compute.requireShieldedVm (must be set as Inactive)
### 3. Use an account (user or service) with Owner + Apigee Org Admin permissions
### 4. Deployment script designed for GKE
### 5. Workload Identity Federation is taken into account by the deployment script

set -e

# Load .env file automatically if it exists
if [ -f "./.env" ]; then
    . ./.env
fi

# ==========================================
# Configuration Variables (Modify these)
# ==========================================
PROJECT_ID="${PROJECT_ID:-my-apigee-project}"
CLUSTER_NAME="${CLUSTER_NAME:-apigee-hybrid-cluster}"
CLUSTER_REGION="${CLUSTER_REGION:-europe-west1}"
NETWORK="${NETWORK:-default}"
SUBNETWORK="${SUBNETWORK:-default}"
APIGEE_ORG="${APIGEE_ORG:-$PROJECT_ID}"
APIGEE_ENV="${APIGEE_ENV:-test}"
APIGEE_ENV_GROUP="${APIGEE_ENV_GROUP:-test-group}"
DOMAIN="${DOMAIN:-1.1.1.1.nip.io}"
GCP_REGION="${GCP_REGION:-europe-west1}"
APIGEE_VERSION="${APIGEE_VERSION:-1.17.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.19.2}"
APIGEE_NAMESPACE="${APIGEE_NAMESPACE:-apigee}"
OVERRIDES_FILE="${OVERRIDES_FILE:-overrides.yaml}"
ENABLE_MCP="${ENABLE_MCP:-false}"
CONTROL_PLANE_LOCATION="${CONTROL_PLANE_LOCATION:-}"
ENABLE_WEB_TRACKER="${ENABLE_WEB_TRACKER:-true}"
TRACKER_HOST="${TRACKER_HOST:-127.0.0.1}"
TRACKER_PORT="${TRACKER_PORT:-8080}"

# Internal runtime flags
MCP_ONLY_MODE="false"
CLI_MCP_FLAG_SET="false"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TRACKER_SCRIPT="${SCRIPT_DIR}/tracker/tracker.py"
CURRENT_TASK_ID=""

# ==========================================
# Helper Functions
# ==========================================
log() {
    if command -v gum >/dev/null 2>&1; then
        gum style --foreground 212 "ℹ $1"
    else
        printf "[INFO] %b\n" "$1"
    fi
}

warn() {
    if command -v gum >/dev/null 2>&1; then
        gum style --foreground 214 "⚠ $1" >&2
    else
        printf "[WARN] %b\n" "$1" >&2
    fi
}

error() {
    if command -v gum >/dev/null 2>&1; then
        gum style --foreground 9 --bold "✖ $1" >&2
    else
        printf "[ERROR] %b\n" "$1" >&2
    fi
    exit 1
}

# ==========================================
# Task Progress Tracking (Web UI)
# ==========================================
begin_task() {
    task_id="$1"
    task_name="$2"
    task_eta="${3:-60}"
    CURRENT_TASK_ID="$task_id"

    if [ "$ENABLE_WEB_TRACKER" = "true" ] && [ -f "$TRACKER_SCRIPT" ] && command -v python3 >/dev/null 2>&1; then
        python3 "$TRACKER_SCRIPT" begin "$task_id" "$task_name" "$task_eta" >/dev/null 2>&1 || true
    fi
    if command -v lab-bootstrap >/dev/null 2>&1; then
        lab-bootstrap begin "$task_id" "$task_name" "$task_eta" >/dev/null 2>&1 || true
    fi
}

end_task() {
    task_id="$1"
    if [ "$ENABLE_WEB_TRACKER" = "true" ] && [ -f "$TRACKER_SCRIPT" ] && command -v python3 >/dev/null 2>&1; then
        python3 "$TRACKER_SCRIPT" end "$task_id" >/dev/null 2>&1 || true
    fi
    if command -v lab-bootstrap >/dev/null 2>&1; then
        lab-bootstrap end "$task_id" >/dev/null 2>&1 || true
    fi
    if [ "$CURRENT_TASK_ID" = "$task_id" ]; then
        CURRENT_TASK_ID=""
    fi
}

fail_task() {
    task_id="$1"
    if [ -z "$task_id" ]; then
        return 0
    fi
    if [ "$ENABLE_WEB_TRACKER" = "true" ] && [ -f "$TRACKER_SCRIPT" ] && command -v python3 >/dev/null 2>&1; then
        python3 "$TRACKER_SCRIPT" fail "$task_id" >/dev/null 2>&1 || true
    fi
    if command -v lab-bootstrap >/dev/null 2>&1; then
        lab-bootstrap fail "$task_id" >/dev/null 2>&1 || true
    fi
}

on_script_exit() {
    exit_code=$?
    if [ "$exit_code" -ne 0 ] && [ -n "$CURRENT_TASK_ID" ]; then
        fail_task "$CURRENT_TASK_ID"
    fi
}

trap 'on_script_exit' EXIT

start_web_tracker() {
    tracker_mode="${1:-full}"
    if [ "$ENABLE_WEB_TRACKER" != "true" ]; then
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$TRACKER_SCRIPT" ]; then
        warn "python3 or tracker/tracker.py not found; skipping web progress tracker."
        return 0
    fi

    python3 "$TRACKER_SCRIPT" init "$tracker_mode" --title "- Lab Startup Tasks -" >/dev/null 2>&1 || true

    if ! curl -s -o /dev/null --max-time 1 "http://${TRACKER_HOST}:${TRACKER_PORT}/status.json" 2>/dev/null; then
        nohup python3 "$TRACKER_SCRIPT" serve --host "$TRACKER_HOST" --port "$TRACKER_PORT" >/dev/null 2>&1 &
        sleep 1
    fi

    log "Web progress tracker available at: http://${TRACKER_HOST}:${TRACKER_PORT}"
}

usage() {
    cat << 'EOF'
Usage: ./deploy_apigee_hybrid.sh [OPTIONS]

Deploy Apigee Hybrid on GKE and optionally enable Model Context Protocol (MCP).

Options:
  --enable-mcp        Enable Apigee MCP Server during full deployment (requires Apigee Hybrid 1.17.0+)
  --no-mcp            Do not enable Apigee MCP Server during deployment
  --enable-mcp-only   Enable Apigee MCP Server on an already existing Apigee Hybrid installation
  --tracker-port PORT Port for the Web progress tracker UI (default: 8080)
  --no-tracker        Disable the Web progress tracker UI
  -h, --help          Display this help message and exit

Environment Variables (can also be configured in .env):
  PROJECT_ID          Google Cloud Project ID
  APIGEE_ORG          Apigee Organization name (defaults to PROJECT_ID)
  APIGEE_VERSION      Apigee Hybrid version (e.g., 1.17.0)
  ENABLE_MCP          Set to "true" or "false" to enable/disable MCP by default
  ENABLE_WEB_TRACKER  Set to "true" or "false" to enable/disable Web tracker (default: true)
  TRACKER_HOST        Bind address for Web tracker (default: 127.0.0.1)
  TRACKER_PORT        Port for Web tracker (default: 8080)
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --enable-mcp)
                ENABLE_MCP="true"
                CLI_MCP_FLAG_SET="true"
                ;;
            --no-mcp)
                ENABLE_MCP="false"
                CLI_MCP_FLAG_SET="true"
                ;;
            --enable-mcp-only|enable-mcp)
                MCP_ONLY_MODE="true"
                ENABLE_MCP="true"
                CLI_MCP_FLAG_SET="true"
                ;;
            --tracker-port)
                shift
                if [ $# -eq 0 ]; then
                    error "--tracker-port requires a port number."
                fi
                TRACKER_PORT="$1"
                ;;
            --no-tracker)
                ENABLE_WEB_TRACKER="false"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1. Use --help for usage information."
                ;;
        esac
        shift
    done
}

prompt_deployment_options() {
    # If an explicit CLI flag was provided, skip interactive prompts
    if [ "$CLI_MCP_FLAG_SET" = "true" ]; then
        return 0
    fi

    # Only prompt if standard input is a terminal
    if [ ! -t 0 ]; then
        return 0
    fi

    # Check if an existing Apigee Hybrid installation is present in the cluster (with short timeout to avoid hanging on stale kubeconfig)
    EXISTING_INSTALL="false"
    if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
        if kubectl get apigeeorganization -n "$APIGEE_NAMESPACE" --request-timeout=5s >/dev/null 2>&1 || \
           helm status "$APIGEE_ORG" -n "$APIGEE_NAMESPACE" >/dev/null 2>&1; then
            EXISTING_INSTALL="true"
        fi
    fi

    if [ "$EXISTING_INSTALL" = "true" ]; then
        log "An existing Apigee Hybrid installation was detected in namespace '$APIGEE_NAMESPACE'."
        if command -v gum >/dev/null 2>&1; then
            CHOICE=$(gum choose \
                --header "Select deployment mode:" \
                "Enable MCP on existing installation only" \
                "Run full deployment (with MCP enabled)" \
                "Run full deployment (without MCP)")
            case "$CHOICE" in
                "Enable MCP on existing installation only")
                    MCP_ONLY_MODE="true"
                    ENABLE_MCP="true"
                    ;;
                "Run full deployment (with MCP enabled)")
                    MCP_ONLY_MODE="false"
                    ENABLE_MCP="true"
                    ;;
                *)
                    MCP_ONLY_MODE="false"
                    ENABLE_MCP="false"
                    ;;
            esac
        else
            printf "Select deployment mode:\n"
            printf "  1) Enable MCP on existing installation only\n"
            printf "  2) Run full deployment (with MCP enabled)\n"
            printf "  3) Run full deployment (without MCP)\n"
            printf "Enter choice [1-3] (default: 1): "
            read -r USER_CHOICE
            case "$USER_CHOICE" in
                2)
                    MCP_ONLY_MODE="false"
                    ENABLE_MCP="true"
                    ;;
                3)
                    MCP_ONLY_MODE="false"
                    ENABLE_MCP="false"
                    ;;
                *)
                    MCP_ONLY_MODE="true"
                    ENABLE_MCP="true"
                    ;;
            esac
        fi
    else
        # No existing installation detected: ask whether to enable MCP during deployment
        if command -v gum >/dev/null 2>&1; then
            if gum confirm "Do you want to enable Apigee Model Context Protocol (MCP) during deployment? (Requires Apigee Hybrid 1.17.0+)"; then
                ENABLE_MCP="true"
            else
                ENABLE_MCP="false"
            fi
        else
            printf "Do you want to enable Apigee Model Context Protocol (MCP) during deployment? [y/N]: "
            read -r MCP_ANS
            case "$MCP_ANS" in
                [yY]|[yY][eE][sS])
                    ENABLE_MCP="true"
                    ;;
                *)
                    ENABLE_MCP="false"
                    ;;
            esac
        fi
    fi
}

print_command() {
    CMD_STR=""
    count=0
    total=$#
    prev_arg=""
    
    C_LBLUE="$(printf '\033[38;5;117m')"
    C_RESET="$(printf '\033[38;5;119m')"
    
    if command -v gum >/dev/null 2>&1; then
        HAS_GUM=1
    else
        HAS_GUM=0
    fi
    
    for orig_arg in "$@"; do
        arg="$orig_arg"
        is_value=0
        
        case "$prev_arg" in
            -*)
                case "$orig_arg" in
                    -*) is_value=0 ;; 
                    *) is_value=1 ;;
                esac
                ;;
        esac
        
        case "$arg" in
            --*=*)
                key="${arg%%=*}"
                val="${arg#*=}"
                case "$val" in
                    *[[:space:]\"\'\$\&\|\;\<\>\(\)\{\}]*)
                        val="$(printf "%s" "$val" | sed "s/'/'\\\\''/g")"
                        val="'$val'"
                        ;;
                esac
                arg="${key}=${C_LBLUE}${val}${C_RESET}"
                ;;
            *)
                case "$arg" in
                    *[[:space:]\"\'\$\&\|\;\<\>\(\)\{\}]*)
                        arg="$(printf "%s" "$arg" | sed "s/'/'\\\\''/g")"
                        arg="'$arg'"
                        ;;
                esac
                
                if [ "$is_value" -eq 1 ]; then
                    arg="${C_LBLUE}${arg}${C_RESET}"
                fi
                ;;
        esac
        
        if [ "$count" -eq 0 ]; then
            CMD_STR="$arg"
        else
            if [ "$total" -gt 3 ]; then
                CMD_STR="${CMD_STR} \\
  $arg"
            else
                CMD_STR="${CMD_STR} $arg"
            fi
        fi
        
        prev_arg="$orig_arg"
        count=$((count + 1))
    done

    if [ "$HAS_GUM" -eq 1 ]; then
        gum style --foreground 212 "↳ Command:"
        # Output cleanly without borders so it's easily copy-pasteable, natively coloring base text 119 (Light Green)
        printf "    \033[38;5;119m%b\033[0m\n" "$CMD_STR"
    else
        printf "  ↳ Command:\n"
        # Use printf to properly evaluate ANSI escapes on all shells consistently
        printf "    \033[38;5;119m%b\033[0m\n" "$CMD_STR"
    fi
}

run_with_spin() {
    TITLE="$1"
    shift
    
    print_command "$@"
    
    TMP_ERR=$(mktemp)

    if command -v gum >/dev/null 2>&1; then
        if ! gum spin --spinner dot --title "$TITLE" -- sh -c ' "$@" > "$0" 2>&1 ' "$TMP_ERR" "$@"; then
            ERR_OUT=$(cat "$TMP_ERR")
            rm -f "$TMP_ERR"
            error "$TITLE failed.
Details:
$ERR_OUT"
        fi
    else
        log "$TITLE"
        if ! "$@" > "$TMP_ERR" 2>&1; then
            ERR_OUT=$(cat "$TMP_ERR")
            rm -f "$TMP_ERR"
            error "$TITLE failed.
Details:
$ERR_OUT"
        fi
    fi
    rm -f "$TMP_ERR"
}

step() {
    STEP_NUM="$1"
    STEP_DESC="$2"
    if command -v gum >/dev/null 2>&1; then
        gum style --border normal --margin "1" --padding "0 2" --border-foreground 212 "Step $STEP_NUM: $STEP_DESC"
    else
        printf "==========================================================\n"
        printf "Step %s: %s\n" "$STEP_NUM" "$STEP_DESC"
        printf "==========================================================\n"
    fi
}

get_env_encoded_name() {
    prefix="$1"
    org="$2"
    env="$3"

    # Calculate short SHA based on "org:env" string
    if command -v shasum >/dev/null 2>&1; then
        sha=$(printf "%s" "${org}:${env}" | shasum -a 256 | cut -c1-7)
    else
        sha=$(printf "%s" "${org}:${env}" | sha256sum | cut -c1-7)
    fi

    # Calculate short names (first 15 characters)
    short_org=$(printf "%s" "${org}" | cut -c1-15)
    short_env=$(printf "%s" "${env}" | cut -c1-15)

    printf "%s\n" "${prefix}-${short_org}-${short_env}-${sha}-sa"
}

get_org_encoded_name() {
    prefix="$1"
    org="$2"

    # Calculate short SHA based on "org" string
    if command -v shasum >/dev/null 2>&1; then
        sha=$(printf "%s" "${org}" | shasum -a 256 | cut -c1-7)
    else
        sha=$(printf "%s" "${org}" | sha256sum | cut -c1-7)
    fi

    # Calculate short name (first 15 characters)
    short_name=$(printf "%s" "${org}" | cut -c1-15)

    printf "%s\n" "${prefix}-${short_name}-${sha}-sa"
}

check_prereqs() {
    log "Checking prerequisites..."
    command -v gcloud >/dev/null 2>&1 || error "gcloud is required but not installed."
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required but not installed."
    command -v helm >/dev/null 2>&1 || error "helm is required but not installed."
    command -v curl >/dev/null 2>&1 || error "curl is required but not installed."
    
    if ! command -v gum >/dev/null 2>&1; then
        printf "[INFO] 'gum' not found. Installing 'gum' for visual tracking...\n"
        if command -v apt >/dev/null 2>&1; then
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gum || warn "Failed to install gum."
        else
            warn "apt not found, skipped gum installation. Execution will proceed without visuals."
        fi
    fi
    log "Prerequisites check completed."
}

# ==========================================
# 1. Prepare Environment & Enable APIs
# ==========================================
setup_project() {
    run_with_spin "Setting current GCP project to $PROJECT_ID..." gcloud config set project "$PROJECT_ID"

    APIS="
        apigee.googleapis.com
        apigeeconnect.googleapis.com
        cloudresourcemanager.googleapis.com
        compute.googleapis.com
        container.googleapis.com
        pubsub.googleapis.com
    "

    log "Enabling necessary GCP APIs for Apigee Hybrid and checking status..."
    for API in $APIS; do
        run_with_spin "Enabling $API..." \
            gcloud services enable "$API" --project "$PROJECT_ID" || warn "Failed to enable $API"
        
        print_command gcloud services list --enabled --project "$PROJECT_ID" --filter="name:$API"
        CHECK_API=$(gcloud services list --enabled --project "$PROJECT_ID" --filter="name:$API")
        if [ -n "$CHECK_API" ]; then
            log "API Status ($API): ENABLED"
        else
            warn "API Status ($API): NOT ENABLED"
        fi
    done
}

# ==========================================
# 2. Setup GKE Cluster (Standard)
# ==========================================
setup_gke() {
    log "Checking if GKE cluster '$CLUSTER_NAME' exists in '$CLUSTER_REGION'..."
    print_command gcloud container clusters describe "$CLUSTER_NAME" --region "$CLUSTER_REGION"
    if gcloud container clusters describe "$CLUSTER_NAME" --region "$CLUSTER_REGION" > /dev/null 2>&1; then
        log "Cluster $CLUSTER_NAME already exists, skipping creation."
    else
        # Note: GKE Standard requires Workload Identity enabled for Apigee hybrid
        run_with_spin "Creating GKE cluster (Standard) '$CLUSTER_NAME'..." gcloud container clusters create "$CLUSTER_NAME" \
            --region "$CLUSTER_REGION" \
            --project "$PROJECT_ID" \
            --network "$NETWORK" \
            --subnetwork "$SUBNETWORK" \
            --machine-type "e2-standard-4" \
            --num-nodes "1" \
            --workload-pool="${PROJECT_ID}.svc.id.goog" \
            --enable-ip-alias \
            --release-channel "regular" \
            --labels mesh_id="proj-${PROJECT_ID}"
            
        run_with_spin "Creating apigee-data node pool..." gcloud container node-pools create "apigee-data" \
            --cluster "$CLUSTER_NAME" \
            --region "$CLUSTER_REGION" \
            --project "$PROJECT_ID" \
            --machine-type "e2-standard-8" \
            --num-nodes "1" \
            --workload-metadata=GKE_METADATA
            
        run_with_spin "Creating apigee-runtime node pool..." gcloud container node-pools create "apigee-runtime" \
            --cluster "$CLUSTER_NAME" \
            --region "$CLUSTER_REGION" \
            --project "$PROJECT_ID" \
            --machine-type "e2-standard-4" \
            --num-nodes "1" \
            --workload-metadata=GKE_METADATA

        run_with_spin "Deleting the default node pool..." gcloud container node-pools delete "default-pool" \
            --cluster "$CLUSTER_NAME" \
            --region "$CLUSTER_REGION" \
            --project "$PROJECT_ID" \
            --quiet
    fi

    run_with_spin "Fetching cluster credentials..." gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$CLUSTER_REGION" --project "$PROJECT_ID"

    log "Setting up Cassandra storage class (apigee-sc) for Apigee hybrid..."
    
    cat <<EOF > apigee-sc.yaml
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: "apigee-sc"
provisioner: kubernetes.io/gce-pd
parameters:
  type: pd-ssd
  replication-type: none
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

    run_with_spin "Applying StorageClass apigee-sc..." kubectl apply -f apigee-sc.yaml
    rm -f apigee-sc.yaml

    run_with_spin "Changing default storage class to apigee-sc..." sh -c '
        kubectl patch storageclass standard-rwo -p "{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}" 2>/dev/null || true
        kubectl patch storageclass standard -p "{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}" 2>/dev/null || true
        kubectl patch storageclass apigee-sc -p "{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}"
    '
}

# ==========================================
# 3. Workload Identity & Service Accounts Preparation
# ==========================================
setup_service_accounts() {
    log "Setting up GCP Service Accounts for Apigee using create-service-account tool..."

    # Define the service accounts required
    SA_LIST="apigee-mart apigee-cassandra apigee-synchronizer apigee-runtime apigee-metrics apigee-watcher apigee-logger apigee-guardrails apigee-mint-task-scheduler"
    
    mkdir -p ./service-accounts
    chmod +x ./apigee-operator/etc/tools/create-service-account

    log "Patching create-service-account to add a 30-second delay before key download..."
    sed -i.bak -e 's/gcloud iam service-accounts keys create/echo "Waiting 30 seconds for IAM propagation..."; sleep 30; gcloud iam service-accounts keys create/g' ./apigee-operator/etc/tools/create-service-account
    rm -f ./apigee-operator/etc/tools/create-service-account.bak

    missing_sa=0
    for SA in $SA_LIST; do
        if ! gcloud iam service-accounts describe "${SA}@${PROJECT_ID}.iam.gserviceaccount.com" > /dev/null 2>&1; then
            missing_sa=1
            break
        fi
    done

    if [ "$missing_sa" -eq 1 ]; then
        log "Running official tool to create missing service accounts (WIF for GKE)..."
        
        # Display the command clearly to the user
        print_command ./apigee-operator/etc/tools/create-service-account \
            --prod \
            --dir ./service-accounts

        # Build a wrapper script to pipe 'y' to the tool to handle its interactive prompts
        cat << 'EOF' > ./create_sas_wrapper.sh
#!/bin/sh
yes | ./apigee-operator/etc/tools/create-service-account \
    --prod \
    --dir ./service-accounts
EOF
        chmod +x ./create_sas_wrapper.sh
        run_with_spin "Provisioning Service Accounts" ./create_sas_wrapper.sh
        rm -f ./create_sas_wrapper.sh
    else
        log "All service accounts already exist. Skipping creation."
    fi
}

# ==========================================
# 3.4 Workload Identity Setup
# ==========================================
bind_wif() {
    SA_NAME="$1"
    KSA_NAME="$2"
    run_with_spin "Binding $SA_NAME to KSA $KSA_NAME" gcloud iam service-accounts add-iam-policy-binding \
        "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
        --role roles/iam.workloadIdentityUser \
        --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${APIGEE_NAMESPACE}/${KSA_NAME}]"
}

setup_workload_identity() {
    log "Setting up Workload Identity bindings for GSA -> KSA..."

    # Org and env scoped wif bindings
    bind_wif "apigee-mart" "$(get_org_encoded_name "apigee-mart" "$APIGEE_ORG")"
    bind_wif "apigee-mart" "$(get_org_encoded_name "apigee-connect-agent" "$APIGEE_ORG")"
    bind_wif "apigee-synchronizer" "$(get_env_encoded_name "apigee-synchronizer" "$APIGEE_ORG" "$APIGEE_ENV")"
    bind_wif "apigee-runtime" "$(get_env_encoded_name "apigee-runtime" "$APIGEE_ORG" "$APIGEE_ENV")"
    bind_wif "apigee-watcher" "$(get_org_encoded_name "apigee-watcher" "$APIGEE_ORG")"
    bind_wif "apigee-mint-task-scheduler" "$(get_org_encoded_name "apigee-mint-task-scheduler" "$APIGEE_ORG")"

    # If MCP is enabled, also bind apigee-watcher GSA to the MCP Server KSA
    if [ "$ENABLE_MCP" = "true" ]; then
        bind_wif "apigee-watcher" "$(get_org_encoded_name "apigee-mcp-server" "$APIGEE_ORG")"
    fi
    
    # Bind Cassandra-related KSAs to the Cassandra backup/objectAdmin SA
    bind_wif apigee-cassandra apigee-cassandra-backup
    bind_wif apigee-cassandra apigee-cassandra-restore
    bind_wif apigee-cassandra apigee-cassandra-schema-setup
    bind_wif apigee-cassandra apigee-cassandra-user-setup

    # Bind operator, logger & metrics sa
    bind_wif apigee-guardrails apigee-operator-guardrails-sa
    bind_wif apigee-logger apigee-logger-apigee-telemetry
    bind_wif apigee-metrics apigee-metrics-sa

    log "Waiting 90 seconds for IAM bindings to propagate across Google Cloud..."
    sleep 90
}

# ==========================================
# 3.5 Networking and TLS Certificates
# ==========================================
setup_networking() {
    log "Setting up Networking & TLS Certificates..."
    
    log "Generating self-signed certificate for *.nip.io..."
    cat > openssl.cnf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
C = US
ST = California
L = San Jose
O = Apigee
CN = *.nip.io

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.nip.io
EOF
    
    # Ensure the target directory for certs exists within the virtualhost charts folder
    mkdir -p apigee-virtualhost/certs
    
    run_with_spin "Executing OpenSSL" openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout apigee-virtualhost/certs/tls.key -out apigee-virtualhost/certs/tls.crt -config openssl.cnf -extensions v3_req || true
}

# ==========================================
# 4. Apigee Organization (Management Plane)
# ==========================================
create_apigee_organization() {
    log "Setting up Apigee Management Plane (Organization).."
    TOKEN=$(gcloud auth print-access-token)
    TMP_RES=$(mktemp)

    log "Checking/Creating Apigee organization '$APIGEE_ORG'..."
    print_command curl -s -w "%{http_code}" -o "$TMP_RES" -H "Authorization: Bearer \$TOKEN" \
         -H "Content-Type: application/json" \
         -X POST -d '{
           "name": "'"$APIGEE_ORG"'",
           "runtimeType": "HYBRID",
           "analyticsRegion": "'"$GCP_REGION"'"
         }' \
         "https://apigee.googleapis.com/v1/organizations?parent=projects/$PROJECT_ID"

    HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMP_RES" -H "Authorization: Bearer $TOKEN" \
         -H "Content-Type: application/json" \
         -X POST -d '{
           "name": "'"$APIGEE_ORG"'",
           "runtimeType": "HYBRID",
           "analyticsRegion": "'"$GCP_REGION"'"
         }' \
         "https://apigee.googleapis.com/v1/organizations?parent=projects/$PROJECT_ID")
         
    if [ "$HTTP_CODE" = "409" ]; then
        log "Organization '$APIGEE_ORG' already exists (HTTP 409). Skipping."
        rm -f "$TMP_RES"
        return 0
    elif [ "$HTTP_CODE" -ge 400 ]; then
        ERR_OUT=$(cat "$TMP_RES")
        rm -f "$TMP_RES"
        error "Failed to create Apigee organization (HTTP $HTTP_CODE).\nDetails:\n$ERR_OUT"
    fi

    # Extract long operation ID ('name' in the JSON output)
    LONG_OP_ID=$(grep -o '"name": *"[^"]*"' "$TMP_RES" | head -1 | awk -F '"' '{print $4}')
    rm -f "$TMP_RES"

    if [ -n "$LONG_OP_ID" ]; then
        log "Organization creation initiated. Polling Operation ID: $LONG_OP_ID"
        while true; do
            TOKEN=$(gcloud auth print-access-token)
            TMP_STATUS=$(mktemp)
            
            print_command curl -s -o "$TMP_STATUS" -H "Authorization: Bearer \$TOKEN" "https://apigee.googleapis.com/v1/$LONG_OP_ID"
            curl -s -o "$TMP_STATUS" -H "Authorization: Bearer $TOKEN" "https://apigee.googleapis.com/v1/$LONG_OP_ID"

            # Check for error field in JSON response
            if grep -q '"error":' "$TMP_STATUS"; then
                ERR_OUT=$(cat "$TMP_STATUS")
                rm -f "$TMP_STATUS"
                error "An error occurred during organization creation:\n$ERR_OUT"
            fi
            
            # Extract state
            STATE=$(grep -o '"state": *"[^"]*"' "$TMP_STATUS" | head -1 | awk -F '"' '{print $4}')
            rm -f "$TMP_STATUS"

            if [ "$STATE" = "ACTIVE" ] || [ "$STATE" = "FINISHED" ]; then
                log "Organization is now $STATE."
                break
            elif echo "$STATE" | grep -qiE "progress"; then
                log "Organization creation in $STATE. Waiting 10 seconds..."
                sleep 10
            else
                log "Current state: $STATE. Waiting 10 seconds..."
                sleep 10
            fi
        done
    else
        log "Could not extract long operation ID from response. Awaiting manually."
        sleep 5
    fi
}

setup_apigee_external_ip() {
    log "Setting up Apigee External IP..."
    
    log "Checking if external IP address 'apigee-ingress-ip' exists..."
    print_command gcloud compute addresses describe apigee-ingress-ip --region "$CLUSTER_REGION" --project "$PROJECT_ID" --format="value(address)"
    
    if gcloud compute addresses describe apigee-ingress-ip --region "$CLUSTER_REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
        log "External IP 'apigee-ingress-ip' already exists. Skipping creation."
    else
        run_with_spin "Reserving external IP address 'apigee-ingress-ip'..." \
            gcloud compute addresses create apigee-ingress-ip --region "$CLUSTER_REGION" --project "$PROJECT_ID"
    fi
    
    ipaddr=$(gcloud compute addresses describe apigee-ingress-ip --region "$CLUSTER_REGION" --project "$PROJECT_ID" --format="value(address)")
    export INGRESS_IP_ADDRESS=${ipaddr}
    export DOMAIN="${ipaddr}.nip.io"
    log "Using configured domain: $DOMAIN"
}

create_apigee_environment_and_group() {
    log "Setting up Apigee Management Plane (Environment & Group).."
    TOKEN=$(gcloud auth print-access-token)

    log "Checking if Environment '$APIGEE_ENV' exists..."
    print_command curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer \$TOKEN" "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/environments/$APIGEE_ENV"
    ENV_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" \
        "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/environments/$APIGEE_ENV")
        
    if [ "$ENV_CHECK" = "200" ]; then
        log "Environment '$APIGEE_ENV' already exists. Skipping creation."
    else
        run_with_spin "Adding environment '$APIGEE_ENV'..." curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" \
             -H "Content-Type: application/json" \
             -X POST -d '{
               "name": "'"$APIGEE_ENV"'"
             }' \
             "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/environments"
    fi
         
    log "Waiting for Environment '$APIGEE_ENV' to become ACTIVE..."
    while true; do
        TOKEN=$(gcloud auth print-access-token)
        TMP_STATE=$(mktemp)
        curl -s -o "$TMP_STATE" -H "Authorization: Bearer $TOKEN" \
            "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/environments/$APIGEE_ENV"
            
        STATE=$(grep -o '"state": *"[^"]*"' "$TMP_STATE" | head -1 | awk -F '"' '{print $4}')
        rm -f "$TMP_STATE"
        
        if [ "$STATE" = "ACTIVE" ]; then
            log "Environment '$APIGEE_ENV' is ACTIVE."
            break
        else
            log "Current environment state: ${STATE:-UNKNOWN}. Waiting 10 seconds..."
            sleep 10
        fi
    done

    log "Checking if Environment Group '$APIGEE_ENV_GROUP' exists..."
    print_command curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer \$TOKEN" "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/envgroups/$APIGEE_ENV_GROUP"
    GRP_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" \
        "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/envgroups/$APIGEE_ENV_GROUP")

    if [ "$GRP_CHECK" = "200" ]; then
        log "Environment Group '$APIGEE_ENV_GROUP' already exists. Skipping creation."
    else
        run_with_spin "Creating environment group '$APIGEE_ENV_GROUP'..." curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" \
             -H "Content-Type: application/json" \
             -X POST -d '{
               "name": "'"$APIGEE_ENV_GROUP"'",
               "hostnames": ["'"$DOMAIN"'"]
             }' \
             "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/envgroups"
    fi

    log "Checking attachment of Environment '$APIGEE_ENV' to Group '$APIGEE_ENV_GROUP'..."
    TMP_ATTACH=$(mktemp)
    print_command curl -s -o "\$TMP_ATTACH" -H "Authorization: Bearer \$TOKEN" "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/envgroups/$APIGEE_ENV_GROUP/attachments"
    curl -s -o "$TMP_ATTACH" -H "Authorization: Bearer $TOKEN" "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/envgroups/$APIGEE_ENV_GROUP/attachments"
    
    if grep -q "\"environment\": *\"$APIGEE_ENV\"" "$TMP_ATTACH"; then
        log "Environment '$APIGEE_ENV' is already attached to Group '$APIGEE_ENV_GROUP'. Skipping attachment."
    else
        run_with_spin "Attaching environment '$APIGEE_ENV' to group '$APIGEE_ENV_GROUP'..." curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" \
             -H "Content-Type: application/json" \
             -X POST -d '{
               "environment": "'"$APIGEE_ENV"'"
             }' \
             "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/envgroups/$APIGEE_ENV_GROUP/attachments"
    fi
    rm -f "$TMP_ATTACH"
}

enable_control_plane_access() {
    TOKEN=$(gcloud auth print-access-token)
    run_with_spin "Enabling Control Plane (Synchronizer) access..." curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type:application/json" \
        "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG:setSyncAuthorization" \
        -d '{"identities":["serviceAccount:apigee-synchronizer@'"$PROJECT_ID"'.iam.gserviceaccount.com"]}' || true

    run_with_spin "Configuring analytics publisher identities..." curl -s -o /dev/null -X PATCH -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type:application/json" \
        "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/controlPlaneAccess?update_mask=analytics_publisher_identities" \
        -d '{"analytics_publisher_identities":["serviceAccount:apigee-mart@'"$PROJECT_ID"'.iam.gserviceaccount.com","serviceAccount:apigee-mint-task-scheduler@'"$PROJECT_ID"'.iam.gserviceaccount.com","serviceAccount:apigee-runtime@'"$PROJECT_ID"'.iam.gserviceaccount.com"]}' || true

    if [ "$ENABLE_MCP" = "true" ]; then
        enable_mcp_control_plane_access
    fi
}

# ==========================================
# Step 9. Install Cert Manager
# ==========================================
install_cert_manager() {
    run_with_spin "Installing cert-manager..." kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml"

    run_with_spin "Waiting for cert-manager to be ready..." kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=300s
}

# ==========================================
# 6. Download Apigee Helm Charts
# ==========================================
download_helm_charts() {
    export CHART_REPO=oci://us-docker.pkg.dev/apigee-release/apigee-hybrid-helm-charts
    export CHART_VERSION="$APIGEE_VERSION"

    log "Checking for existing Helm charts and cleaning up..."
    CHARTS="apigee-operator apigee-datastore apigee-env apigee-ingress-manager apigee-org apigee-redis apigee-telemetry apigee-virtualhost"
    for chart in $CHARTS; do
        if [ -d "$chart" ]; then
            log "Found existing directory $chart, deleting it..."
            rm -rf "$chart"
        fi
    done

    run_with_spin "Pulling Apigee Operator chart..." helm pull $CHART_REPO/apigee-operator --version $CHART_VERSION --untar
    run_with_spin "Pulling Apigee Datastore chart..." helm pull $CHART_REPO/apigee-datastore --version $CHART_VERSION --untar
    run_with_spin "Pulling Apigee Env chart..." helm pull $CHART_REPO/apigee-env --version $CHART_VERSION --untar
    run_with_spin "Pulling Apigee Ingress chart..." helm pull $CHART_REPO/apigee-ingress-manager --version $CHART_VERSION --untar
    run_with_spin "Pulling Apigee Org chart..." helm pull $CHART_REPO/apigee-org --version $CHART_VERSION --untar
    run_with_spin "Pulling Apigee Redis chart..." helm pull $CHART_REPO/apigee-redis --version $CHART_VERSION --untar
    run_with_spin "Pulling Apigee Telemetry chart..." helm pull $CHART_REPO/apigee-telemetry --version $CHART_VERSION --untar
    run_with_spin "Pulling Apigee Virtualhost chart..." helm pull $CHART_REPO/apigee-virtualhost --version $CHART_VERSION --untar
}

# ==========================================
# 7. Install Apigee CRDs
# ==========================================
install_crds() {
    log "Installing Apigee CRDs..."
    if [ "$APIGEE_NAMESPACE" != "apigee" ]; then
        log "Patching CRD namespace to $APIGEE_NAMESPACE in kustomization.yaml..."
        sed -i.bak "s/namespace: apigee/namespace: $APIGEE_NAMESPACE/g" apigee-operator/etc/crds/default/kustomization.yaml
        rm -f apigee-operator/etc/crds/default/kustomization.yaml.bak
    fi

    run_with_spin "Applying Apigee operator CRDs..." kubectl apply -k "apigee-operator/etc/crds/default/" \
        --server-side \
        --force-conflicts \
        --validate=false

    run_with_spin "Verifying Apigee CRDs..." kubectl get crds
    kubectl get crds | grep apigee || true
}

# ==========================================
# 8. Install Helm Charts (Apigee Components)
# ==========================================
check_overrides() {
    log "Checking for overrides file: $OVERRIDES_FILE"
    if [ ! -f "$OVERRIDES_FILE" ]; then
        warn "Overrides file '$OVERRIDES_FILE' not found. Creating a minimal template."
        cat <<EOF > "$OVERRIDES_FILE"
# This file is generated by the Apigee Hybrid for GKE deployment script
instanceID: "apigee-hybrid-1"
namespace: "$APIGEE_NAMESPACE"
gcp:
  projectID: "$PROJECT_ID"
  region: "$GCP_REGION"
  workloadIdentity:
    enabled: true
org: "$APIGEE_ORG"

k8sCluster:
  name: "$CLUSTER_NAME"
  region: "$GCP_REGION"

# Component Workload Identity References
mart:
  gsa: "apigee-mart@${PROJECT_ID}.iam.gserviceaccount.com"

connectAgent:
  gsa: "apigee-mart@${PROJECT_ID}.iam.gserviceaccount.com"

metrics:
  gsa: "apigee-metrics@${PROJECT_ID}.iam.gserviceaccount.com"

synchronizer:
  gsa: "apigee-synchronizer@${PROJECT_ID}.iam.gserviceaccount.com"

watcher:
  gsa: "apigee-watcher@${PROJECT_ID}.iam.gserviceaccount.com"

guardrails:
  gsa: "apigee-guardrails@${PROJECT_ID}.iam.gserviceaccount.com"

logger:
  enabled: true
  gsa: "apigee-logger@${PROJECT_ID}.iam.gserviceaccount.com"

runtime:
  gsa: "apigee-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
  replicaCountMin: 2
  replicaCountMax: 5

mintTaskScheduler:
  gsa: "apigee-mint-task-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"

cassandra:
  # Set to false for single region installations and for multi-region
  # installations with connectivity between pods in different clusters,
  # like GKE.
  # Set to true for multi-region installations with no communication
  # between pods in different clusters, for example Google Distributed
  # Cloud on VMware or bare metal, GKE on AWS, AKS, EKS, and OpenShift.
  # See Multi-region deployment: Prerequisites
  hostNetwork: false
  replicaCount: 3
  storage:
    storageclass: "apigee-sc"

envs:
  - name: "$APIGEE_ENV"
    gsa:
      synchronizer: "apigee-synchronizer@${PROJECT_ID}.iam.gserviceaccount.com"
      runtime: "apigee-runtime@${PROJECT_ID}.iam.gserviceaccount.com"

enhanceProxyLimits: true

ingressGateways:
  - name: apigee-ingress
    replicaCountMin: 2
    replicaCountMax: 10
    svcLoadBalancerIP: $INGRESS_IP_ADDRESS
    svcType: LoadBalancer

virtualhosts:
  - name: "$APIGEE_ENV_GROUP"
    selector:
      app: apigee-ingressgateway
      ingress_name: apigee-ingress
    sslSecret: "apigee-tls-secret"
EOF
        warn "Please ensure $OVERRIDES_FILE matches your environment requirements before proceeding to production."
    fi

    if [ "$ENABLE_MCP" = "true" ]; then
        configure_mcp_in_overrides
    fi
}

install_apigee_operator() {
    run_with_spin "Installing Apigee Operator..." helm upgrade operator apigee-operator/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --create-namespace \
        --atomic \
        -f "$OVERRIDES_FILE"
    
    # Wait for operator (bypassing strict label selectors by finding pods directly)
    run_with_spin "Waiting for Apigee Operator..." sh -c '
        PODS=$(kubectl get pods -n "'"$APIGEE_NAMESPACE"'" -o name | grep -E "apigee-operator|apigee-controller")
        for pod in $PODS; do
            kubectl -n "'"$APIGEE_NAMESPACE"'" wait --for=condition=Ready "$pod" --timeout=150s
        done
    ' || true
}

install_apigee_datastore() {
    run_with_spin "Installing Apigee Datastore..." helm upgrade datastore apigee-datastore/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        -f "$OVERRIDES_FILE"
    
    # Wait for datastore
    run_with_spin "Waiting for Cassandra Datastore..." sh -c '
        PODS=$(kubectl get pods -n "'"$APIGEE_NAMESPACE"'" -o name | grep -E "apigee-cassandra")
        for pod in $PODS; do
            kubectl -n "'"$APIGEE_NAMESPACE"'" wait --for=condition=Ready "$pod" --timeout=900s
        done
    ' || true
}

install_apigee_telemetry() {
    run_with_spin "Installing Apigee Telemetry..." helm upgrade telemetry apigee-telemetry/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        -f "$OVERRIDES_FILE"
}

install_apigee_redis() {
    run_with_spin "Installing Apigee Redis..." helm upgrade redis apigee-redis/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        -f "$OVERRIDES_FILE"
}

install_apigee_ingress_manager() {
    run_with_spin "Installing Apigee Ingress Manager..." helm upgrade ingress-manager apigee-ingress-manager/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        -f "$OVERRIDES_FILE"
}

install_apigee_org() {
    run_with_spin "Installing Apigee Organization ($APIGEE_ORG)..." helm upgrade "$APIGEE_ORG" apigee-org/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        -f "$OVERRIDES_FILE"
}

install_apigee_env() {
    # ENV_RELEASE_NAME is typically the environment name
    run_with_spin "Installing Apigee Environment ($APIGEE_ENV)..." helm upgrade "$APIGEE_ENV" apigee-env/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        --set env="$APIGEE_ENV" \
        -f "$OVERRIDES_FILE"
}

install_apigee_env_group() {
    run_with_spin "Creating Kubernetes Context TLS Secret..." sh -c "
        kubectl get namespace \"$APIGEE_NAMESPACE\" >/dev/null 2>&1 || kubectl create namespace \"$APIGEE_NAMESPACE\"
        kubectl create secret tls apigee-tls-secret \
            --cert=apigee-virtualhost/certs/tls.crt \
            --key=apigee-virtualhost/certs/tls.key \
            -n \"$APIGEE_NAMESPACE\" \
            --dry-run=client -o yaml | kubectl apply -f -
    "

    # ENV_GROUP_RELEASE_NAME is typically the env group name
    run_with_spin "Installing Apigee Environment Group / Virtualhosts ($APIGEE_ENV_GROUP)..." helm upgrade "$APIGEE_ENV_GROUP" apigee-virtualhost/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        --set envgroup="$APIGEE_ENV_GROUP" \
        -f "$OVERRIDES_FILE"
}

create_apigee_namespace() {
    log "Setting up Apigee Kubernetes Namespace..."
    print_command kubectl get namespace "$APIGEE_NAMESPACE"
    
    if kubectl get namespace "$APIGEE_NAMESPACE" >/dev/null 2>&1; then
        log "Kubernetes Namespace '$APIGEE_NAMESPACE' already exists."
    else
        log "Creating Kubernetes Namespace '$APIGEE_NAMESPACE'..."
        print_command kubectl create namespace "$APIGEE_NAMESPACE"
        CMD_OUT=$(kubectl create namespace "$APIGEE_NAMESPACE" 2>&1)
        
        if [ $? -eq 0 ]; then
            printf "%s\n" "$CMD_OUT" | awk '{print "    " $0}'
        else
            error "Failed to create namespace '$APIGEE_NAMESPACE'.\nDetails:\n$CMD_OUT"
        fi
    fi
}

# ==========================================
# 9. Apigee Model Context Protocol (MCP) Enablement
# Reference: https://docs.cloud.google.com/apigee/docs/api-platform/apigee-mcp/enable-mcp
# ==========================================
check_mcp_version_compatibility() {
    log "Checking Apigee Hybrid version compatibility for MCP (requires 1.17.0 or later)..."
    MAJOR_VER=$(printf "%s" "$APIGEE_VERSION" | awk -F. '{print $1}')
    MINOR_VER=$(printf "%s" "$APIGEE_VERSION" | awk -F. '{print $2}')

    if [ -z "$MAJOR_VER" ] || [ -z "$MINOR_VER" ]; then
        error "Invalid APIGEE_VERSION format: '$APIGEE_VERSION'. Expected semantic version (e.g., 1.17.0)."
    fi

    if [ "$MAJOR_VER" -lt 1 ] || { [ "$MAJOR_VER" -eq 1 ] && [ "$MINOR_VER" -lt 17 ]; }; then
        error "Apigee Model Context Protocol (MCP) requires Apigee Hybrid version 1.17.0 or later (current APIGEE_VERSION: $APIGEE_VERSION)."
    fi
    log "Version $APIGEE_VERSION is compatible with Apigee MCP."

    # Check if local Helm chart directories exist and match the required version
    CHARTS_NEED_PULL=0
    if [ ! -f "apigee-operator/Chart.yaml" ] || [ ! -f "apigee-org/Chart.yaml" ]; then
        CHARTS_NEED_PULL=1
    else
        LOCAL_OP_VER=$(awk '/^version:/{gsub(/["'\'']/, "", $2); print $2}' apigee-operator/Chart.yaml | head -1)
        if [ "$LOCAL_OP_VER" != "$APIGEE_VERSION" ]; then
            warn "Local Helm chart version ($LOCAL_OP_VER) does not match APIGEE_VERSION ($APIGEE_VERSION)."
            CHARTS_NEED_PULL=1
        fi
    fi

    if [ "$CHARTS_NEED_PULL" -eq 1 ]; then
        log "Downloading Apigee Helm charts for version $APIGEE_VERSION..."
        download_helm_charts
    fi
}

# Step 1: Edit overrides.yaml to include top-level enableMcpServer: true
configure_mcp_in_overrides() {
    log "Configuring 'enableMcpServer: true' in $OVERRIDES_FILE..."
    if [ ! -f "$OVERRIDES_FILE" ]; then
        check_overrides
        return 0
    fi

    if grep -q "^enableMcpServer:" "$OVERRIDES_FILE"; then
        sed -i.bak 's/^enableMcpServer:.*/enableMcpServer: true/' "$OVERRIDES_FILE"
        rm -f "${OVERRIDES_FILE}.bak"
        log "Updated existing 'enableMcpServer' setting to 'true' in $OVERRIDES_FILE."
    else
        cat << 'EOF' >> "$OVERRIDES_FILE"

# ---- MCP: minimum required -------------------------------------------------
enableMcpServer: true
EOF
        log "Appended 'enableMcpServer: true' to $OVERRIDES_FILE."
    fi
}

# Step 2: Grant the watcher identity access to the MCP configuration on the control plane
enable_mcp_control_plane_access() {
    log "Granting apigee-watcher identity access to MCP configuration on the Control Plane..."
    TOKEN=$(gcloud auth print-access-token)

    WATCHER_SA="apigee-watcher@${PROJECT_ID}.iam.gserviceaccount.com"
    if [ -f "$OVERRIDES_FILE" ]; then
        EXTRACTED_SA=$(awk '/^watcher:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && /gsa:/{gsub(/["'\'']/, "", $2); print $2}' "$OVERRIDES_FILE" | head -1)
        if [ -n "$EXTRACTED_SA" ]; then
            WATCHER_SA="$EXTRACTED_SA"
        fi
    fi

    if [ -n "$CONTROL_PLANE_LOCATION" ]; then
        CPA_BASE="https://${CONTROL_PLANE_LOCATION}-apigee.googleapis.com/v1"
    else
        CPA_BASE="https://apigee.googleapis.com/v1"
    fi
    CPA_URL="${CPA_BASE}/organizations/${APIGEE_ORG}/controlPlaneAccess"

    print_command curl -s -X PATCH -H "Authorization: Bearer \$TOKEN" \
        -H "Content-Type: application/json" \
        "${CPA_URL}?update_mask=watcher_identities" \
        -d "{\"watcher_identities\": [\"serviceAccount:${WATCHER_SA}\"]}"

    CPA_RETRY=0
    CPA_MAX_RETRIES=24
    while true; do
        TOKEN=$(gcloud auth print-access-token)
        TMP_CPA=$(mktemp)
        HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMP_CPA" -X PATCH \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            "${CPA_URL}?update_mask=watcher_identities" \
            -d "{\"watcher_identities\": [\"serviceAccount:${WATCHER_SA}\"]}")

        if [ "$HTTP_CODE" -lt 400 ]; then
            break
        fi

        if grep -qiE "locked by another operation|FAILED_PRECONDITION|ABORTED" "$TMP_CPA" && [ "$CPA_RETRY" -lt "$CPA_MAX_RETRIES" ]; then
            LOCK_OP=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$TMP_CPA" | head -1)
            rm -f "$TMP_CPA"
            CPA_RETRY=$((CPA_RETRY + 1))
            log "Control Plane resource is locked by ongoing operation (${LOCK_OP:-in-progress}). Waiting 5s before retry (${CPA_RETRY}/${CPA_MAX_RETRIES})..."
            sleep 5
            continue
        fi

        ERR_OUT=$(cat "$TMP_CPA")
        rm -f "$TMP_CPA"
        error "Failed to update controlPlaneAccess for watcher_identities (HTTP $HTTP_CODE).\nDetails:\n$ERR_OUT"
    done

    # Wait for long-running operation if returned by the API
    LRO_NAME=$(grep -o '"name": *"organizations/[^"]*operations/[^"]*"' "$TMP_CPA" | head -1 | awk -F '"' '{print $4}')
    rm -f "$TMP_CPA"

    if [ -n "$LRO_NAME" ]; then
        log "Waiting for controlPlaneAccess operation ($LRO_NAME) to complete..."
        while true; do
            TOKEN=$(gcloud auth print-access-token)
            TMP_OP=$(mktemp)
            curl -s -o "$TMP_OP" -H "Authorization: Bearer $TOKEN" "${CPA_BASE}/${LRO_NAME}"
            if grep -q '"done": *true' "$TMP_OP"; then
                rm -f "$TMP_OP"
                break
            fi
            rm -f "$TMP_OP"
            sleep 5
        done
    fi

    # Verify the grant landed using getControlPlaneAccess
    log "Verifying watcherIdentities grant on controlPlaneAccess..."
    TMP_VERIFY=$(mktemp)
    print_command curl -s -X GET -H "Authorization: Bearer \$TOKEN" \
        -H "Content-Type: application/json" \
        "$CPA_URL"
    curl -s -o "$TMP_VERIFY" -X GET \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "$CPA_URL"

    if grep -q "serviceAccount:${WATCHER_SA}" "$TMP_VERIFY"; then
        log "Verified: watcher service account '${WATCHER_SA}' is present in watcherIdentities."
        rm -f "$TMP_VERIFY"
    else
        ERR_OUT=$(cat "$TMP_VERIFY")
        rm -f "$TMP_VERIFY"
        error "Verification failed: '${WATCHER_SA}' not found in watcherIdentities.\nResponse:\n$ERR_OUT"
    fi
}

# Ensure GKE Workload Identity IAM binding for MCP Server KSA -> apigee-watcher GSA
ensure_mcp_workload_identity() {
    log "Ensuring Workload Identity bindings for MCP Server ServiceAccount..."
    bind_wif "apigee-watcher" "$(get_org_encoded_name "apigee-watcher" "$APIGEE_ORG")"
    bind_wif "apigee-watcher" "$(get_org_encoded_name "apigee-mcp-server" "$APIGEE_ORG")"

    # Also bind any dynamically created apigee-mcp-server KSA in the cluster
    MCP_KSAS=$(kubectl get sa -n "$APIGEE_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep '^apigee-mcp-server' || true)
    for ksa in $MCP_KSAS; do
        bind_wif "apigee-watcher" "$ksa"
    done
}

# Step 3 & Step 4: Upgrade apigee-operator chart first, then apigee-org chart
upgrade_mcp_helm_charts() {
    log "Applying Apigee CRDs for version $APIGEE_VERSION..."
    install_crds

    # Detect existing Helm release name for apigee-operator (defaults to 'operator')
    DETECTED_OP_RELEASE=$(helm list -n "$APIGEE_NAMESPACE" 2>/dev/null | awk '$9 ~ /apigee-operator/ {print $1; exit}')
    APIGEE_OPERATOR_RELEASE_NAME="${APIGEE_OPERATOR_RELEASE_NAME:-${DETECTED_OP_RELEASE:-operator}}"

    log "Step 3: Upgrading apigee-operator chart (release: $APIGEE_OPERATOR_RELEASE_NAME)..."
    run_with_spin "Upgrading apigee-operator Helm release..." helm upgrade "$APIGEE_OPERATOR_RELEASE_NAME" apigee-operator/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --create-namespace \
        --atomic \
        -f "$OVERRIDES_FILE"

    run_with_spin "Confirming apigee-controller-manager deployment rollout..." \
        kubectl rollout status deploy -n "$APIGEE_NAMESPACE" apigee-controller-manager --timeout=2m

    # Detect existing Helm release name for apigee-org (defaults to APIGEE_ORG)
    DETECTED_ORG_RELEASE=$(helm list -n "$APIGEE_NAMESPACE" 2>/dev/null | awk '$9 ~ /apigee-org/ {print $1; exit}')
    APIGEE_ORG_RELEASE_NAME="${APIGEE_ORG_RELEASE_NAME:-${DETECTED_ORG_RELEASE:-$APIGEE_ORG}}"

    log "Step 4: Upgrading apigee-org chart (release: $APIGEE_ORG_RELEASE_NAME)..."
    run_with_spin "Upgrading apigee-org Helm release..." helm upgrade "$APIGEE_ORG_RELEASE_NAME" apigee-org/ \
        --install \
        --namespace "$APIGEE_NAMESPACE" \
        --atomic \
        -f "$OVERRIDES_FILE"
}

# Step 5: Verify the MCP installation
verify_mcp_installation() {
    log "Step 5: Verifying Apigee MCP Server installation in namespace '$APIGEE_NAMESPACE'..."

    # Ensure Workload Identity is bound for any newly created MCP KSA
    ensure_mcp_workload_identity

    # 1. Verify MCP ApigeeDeployment and Pods
    log "Waiting for MCP ApigeeDeployment and pods (label: app=apigee-mcp-server)..."
    WAIT_COUNT=0
    while [ "$WAIT_COUNT" -lt 30 ]; do
        MCP_PODS=$(kubectl get pods -n "$APIGEE_NAMESPACE" -l app=apigee-mcp-server -o name 2>/dev/null || true)
        if [ -n "$MCP_PODS" ]; then
            break
        fi
        log "Waiting for MCP pods to be scheduled... ($((WAIT_COUNT * 10))s elapsed)"
        sleep 10
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    if [ -z "$MCP_PODS" ]; then
        error "No MCP pods (app=apigee-mcp-server) found in namespace '$APIGEE_NAMESPACE' after 300s."
    fi

    run_with_spin "Waiting for MCP pods to reach Ready state (2/2 Running)..." \
        kubectl wait --for=condition=Ready pod -l app=apigee-mcp-server -n "$APIGEE_NAMESPACE" --timeout=300s

    log "Inspecting MCP ApigeeDeployment custom resource:"
    print_command kubectl get apigeedeployment -n "$APIGEE_NAMESPACE" -l app=apigee-mcp-server
    kubectl get apigeedeployment -n "$APIGEE_NAMESPACE" -l app=apigee-mcp-server || true

    log "Inspecting MCP Pods:"
    print_command kubectl get pod -n "$APIGEE_NAMESPACE" -l app=apigee-mcp-server
    kubectl get pod -n "$APIGEE_NAMESPACE" -l app=apigee-mcp-server || true

    # 2. Verify MCP Service
    log "Inspecting MCP Service:"
    print_command kubectl get svc -n "$APIGEE_NAMESPACE" -l app=apigee-mcp-server
    kubectl get svc -n "$APIGEE_NAMESPACE" -l app=apigee-mcp-server || true

    # 3. Verify MCP HorizontalPodAutoscaler
    log "Inspecting MCP HorizontalPodAutoscaler:"
    print_command kubectl get hpa -n "$APIGEE_NAMESPACE"
    kubectl get hpa -n "$APIGEE_NAMESPACE" | grep apigee-mcp-server || true

    # 4. Verify Message Processor pods received the hostAliases entry
    log "Verifying Message Processor (apigee-runtime) pods received MCP hostAliases..."
    MP_PODS=$(kubectl get pods -n "$APIGEE_NAMESPACE" -l app=apigee-runtime -o name 2>/dev/null || true)
    if [ -n "$MP_PODS" ]; then
        MISSING_ALIAS=0
        for mp_pod in $MP_PODS; do
            ALIAS_CHECK=$(kubectl get "$mp_pod" -n "$APIGEE_NAMESPACE" -o jsonpath='{.spec.hostAliases}' 2>/dev/null || true)
            case "$ALIAS_CHECK" in
                *mcp.apigee.internal*) ;;
                *) MISSING_ALIAS=1 ;;
            esac
        done

        if [ "$MISSING_ALIAS" -eq 1 ]; then
            warn "One or more Message Processor pods are missing the MCP hostAliases entry."
            log "Forcing fresh staged canary release by deleting current Message Processor pods..."
            run_with_spin "Deleting apigee-runtime pods to refresh spec..." \
                kubectl delete pod -n "$APIGEE_NAMESPACE" -l app=apigee-runtime
            sleep 10
            run_with_spin "Waiting for new Message Processor pods to be Ready..." \
                kubectl wait --for=condition=Ready pod -l app=apigee-runtime -n "$APIGEE_NAMESPACE" --timeout=300s
        fi

        log "Message Processor hostAliases verification:"
        print_command kubectl get pods -n "$APIGEE_NAMESPACE" -l app=apigee-runtime \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.hostAliases}{"\n"}{end}'
        kubectl get pods -n "$APIGEE_NAMESPACE" -l app=apigee-runtime \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.hostAliases}{"\n"}{end}' || true
    else
        warn "No Message Processor pods (app=apigee-runtime) found in namespace '$APIGEE_NAMESPACE'."
    fi

    log "=========================================================="
    log "Apigee MCP Server enablement and verification completed!"
    log "=========================================================="
}

# Standalone flow to enable MCP on an already existing Apigee Hybrid installation
enable_mcp_on_existing() {
    log "Starting Apigee MCP Enablement on existing Apigee Hybrid installation..."
    start_web_tracker "mcp-only"

    begin_task "mcp-version" "Check Apigee Hybrid version & Helm charts" 30
    check_mcp_version_compatibility
    end_task "mcp-version"

    # Ensure kubectl context is configured for the target cluster
    begin_task "mcp-creds" "Fetch GKE cluster credentials" 15
    run_with_spin "Fetching cluster credentials..." \
        gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$CLUSTER_REGION" --project "$PROJECT_ID"
    end_task "mcp-creds"

    step "MCP-1" "Edit overrides.yaml to enable MCP Server"
    begin_task "mcp-overrides" "Configure enableMcpServer in overrides.yaml" 10
    configure_mcp_in_overrides
    end_task "mcp-overrides"

    step "MCP-2" "Grant watcher identity access to MCP configuration on Control Plane"
    begin_task "mcp-cpa" "Grant watcher identity access on Control Plane" 30
    enable_mcp_control_plane_access
    end_task "mcp-cpa"

    step "MCP-3" "Ensure Workload Identity bindings for MCP"
    begin_task "mcp-wif" "Ensure Workload Identity bindings for MCP" 30
    ensure_mcp_workload_identity
    end_task "mcp-wif"

    step "MCP-4" "Upgrade apigee-operator and apigee-org Helm charts"
    begin_task "mcp-helm" "Upgrade apigee-operator and apigee-org charts" 180
    upgrade_mcp_helm_charts
    end_task "mcp-helm"

    step "MCP-5" "Verify MCP data plane installation & Message Processor hostAliases"
    begin_task "mcp-verify" "Verify MCP installation & MP hostAliases" 120
    verify_mcp_installation
    end_task "mcp-verify"
}

# ==========================================
# Main Execution
# ==========================================
main() {
    parse_args "$@"
    check_prereqs
    prompt_deployment_options

    # If standalone MCP enablement mode is selected for an existing installation
    if [ "$MCP_ONLY_MODE" = "true" ]; then
        enable_mcp_on_existing
        exit 0
    fi

    if [ "$ENABLE_MCP" = "true" ]; then
        start_web_tracker "full-mcp"
    else
        start_web_tracker "full"
    fi

    log "Starting Apigee Hybrid v${APIGEE_VERSION} GKE Deployment Script (MCP Enabled: ${ENABLE_MCP})..."
    if [ "$ENABLE_MCP" = "true" ]; then
        check_mcp_version_compatibility
    fi
    
    step 1 "Create a Cluster"
    begin_task "setup-project" "Prepare GCP project & enable APIs" 60
    setup_project
    end_task "setup-project"

    begin_task "setup-gke" "Create GKE cluster & node pools" 600
    setup_gke
    end_task "setup-gke"
    
    step "1a" "Create an Apigee hybrid organization"
    begin_task "create-org" "Create Apigee hybrid organization" 180
    create_apigee_organization
    end_task "create-org"
    
    step "1b" "Create an external IP address for ingress"
    begin_task "create-ip" "Reserve external IP address for ingress" 30
    setup_apigee_external_ip
    end_task "create-ip"

    step "1c" "Create an environment & env. group"
    begin_task "create-env" "Create Apigee environment & env group" 120
    create_apigee_environment_and_group
    end_task "create-env"
    
    step 2 "Download the Apigee Helm charts"
    begin_task "download-charts" "Download Apigee hybrid Helm charts" 45
    download_helm_charts
    end_task "download-charts"
    
    step 3 "Create the apigee namespace"
    begin_task "create-ns" "Create Kubernetes apigee namespace" 10
    create_apigee_namespace
    end_task "create-ns"
    
    step 4 "Create service accounts"
    begin_task "create-sa" "Create GCP Service Accounts" 300
    setup_service_accounts
    end_task "create-sa"
    
    step 5 "Set up service account authentication"
    begin_task "setup-wif" "Configure Workload Identity bindings" 150
    setup_workload_identity
    end_task "setup-wif"
    
    step 6 "Create TLS certificates"
    begin_task "create-certs" "Generate TLS certificates" 15
    setup_networking
    end_task "create-certs"
    
    step 7 "Create the overrides"
    if [ "$ENABLE_MCP" = "true" ]; then
        begin_task "create-overrides" "Create & configure overrides.yaml (MCP enabled)" 10
    else
        begin_task "create-overrides" "Create & configure overrides.yaml" 10
    fi
    check_overrides
    end_task "create-overrides"
    
    step 8 "Enable Control Plane access"
    if [ "$ENABLE_MCP" = "true" ]; then
        begin_task "enable-cpa" "Enable Control Plane & MCP watcher access" 30
    else
        begin_task "enable-cpa" "Enable Control Plane access" 30
    fi
    enable_control_plane_access
    end_task "enable-cpa"
    
    step 9 "Install cert-manager"
    begin_task "install-certmgr" "Install cert-manager on GKE" 90
    install_cert_manager
    end_task "install-certmgr"
    
    step 10 "Install the Apigee hybrid CRDs"
    begin_task "install-crds" "Install Apigee hybrid CRDs" 30
    install_crds
    end_task "install-crds"
    
    step 11 "Install Apigee hybrid Using Helm"
    begin_task "helm-operator" "Install Apigee Operator (Helm)" 120
    install_apigee_operator
    end_task "helm-operator"

    begin_task "helm-datastore" "Install Apigee Cassandra Datastore (Helm)" 480
    install_apigee_datastore
    end_task "helm-datastore"

    begin_task "helm-telemetry" "Install Apigee Telemetry (Helm)" 90
    install_apigee_telemetry
    end_task "helm-telemetry"

    begin_task "helm-redis" "Install Apigee Redis (Helm)" 120
    install_apigee_redis
    end_task "helm-redis"

    begin_task "helm-ingress" "Install Apigee Ingress Manager (Helm)" 90
    install_apigee_ingress_manager
    end_task "helm-ingress"

    begin_task "helm-org" "Install Apigee Organization (Helm)" 180
    install_apigee_org
    end_task "helm-org"

    begin_task "helm-env" "Install Apigee Environment (Helm)" 240
    install_apigee_env
    end_task "helm-env"

    begin_task "helm-envgroup" "Install Apigee Env Group / Virtualhost (Helm)" 120
    install_apigee_env_group
    end_task "helm-envgroup"

    if [ "$ENABLE_MCP" = "true" ]; then
        step 12 "Verify Apigee MCP Server Installation"
        begin_task "verify-mcp" "Verify Apigee MCP Server installation" 120
        verify_mcp_installation
        end_task "verify-mcp"
    fi

    log "=========================================================="
    log "Apigee Hybrid Deployment Complete!"
    log "Next steps required for full functionality:"
    log ". Setup Ingress routing/load balancer point."
    if [ "$ENABLE_WEB_TRACKER" = "true" ]; then
        log ". Web progress tracker: http://${TRACKER_HOST}:${TRACKER_PORT}"
    fi
    log "=========================================================="
}

main "$@"


