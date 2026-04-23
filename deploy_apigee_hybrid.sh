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
APIGEE_VERSION="${APIGEE_VERSION:-1.16.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.19.2}"
APIGEE_NAMESPACE="apigee"
OVERRIDES_FILE="${OVERRIDES_FILE:-overrides.yaml}"

# ==========================================
# Helper Functions
# ==========================================
log() {
    if command -v gum >/dev/null 2>&1; then
        gum style --foreground 212 "ℹ $1"
    else
        echo "[INFO] $1"
    fi
}

warn() {
    if command -v gum >/dev/null 2>&1; then
        gum style --foreground 214 "⚠ $1" >&2
    else
        echo "[WARN] $1" >&2
    fi
}

error() {
    if command -v gum >/dev/null 2>&1; then
        gum style --foreground 9 --bold "✖ $1" >&2
    else
        echo "[ERROR] $1" >&2
    fi
    exit 1
}

print_command() {
    local CMD_STR=""
    local count=0
    local total=$#
    local prev_arg=""
    
    local C_LBLUE="$(printf '\033[38;5;117m')"
    local C_RESET="$(printf '\033[38;5;119m')"
    
    if command -v gum >/dev/null 2>&1; then
        local HAS_GUM=1
    else
        local HAS_GUM=0
    fi
    
    for orig_arg in "$@"; do
        local arg="$orig_arg"
        local is_value=0
        
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
                local key="${arg%%=*}"
                local val="${arg#*=}"
                case "$val" in
                    *[[:space:]\"\'\$\&\|\;\<\>\(\)\{\}]*)
                        val="$(echo "$val" | sed "s/'/'\\\\''/g")"
                        val="'$val'"
                        ;;
                esac
                arg="${key}=${C_LBLUE}${val}${C_RESET}"
                ;;
            *)
                case "$arg" in
                    *[[:space:]\"\'\$\&\|\;\<\>\(\)\{\}]*)
                        arg="$(echo "$arg" | sed "s/'/'\\\\''/g")"
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
        echo "  ↳ Command:"
        # Use printf to properly evaluate ANSI escapes on all shells consistently
        printf "    \033[38;5;119m%b\033[0m\n" "$CMD_STR"
    fi
}

run_with_spin() {
    TITLE="$1"
    shift
    
    print_command "$@"
    
    local TMP_ERR
    TMP_ERR=$(mktemp)

    if command -v gum >/dev/null 2>&1; then
        if ! gum spin --spinner dot --title "$TITLE" -- sh -c ' "$@" > "$0" 2>&1 ' "$TMP_ERR" "$@"; then
            local ERR_OUT
            ERR_OUT=$(cat "$TMP_ERR")
            rm -f "$TMP_ERR"
            error "$TITLE failed.
Details:
$ERR_OUT"
        fi
    else
        log "$TITLE"
        if ! "$@" > "$TMP_ERR" 2>&1; then
            local ERR_OUT
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
    local STEP_NUM="$1"
    local STEP_DESC="$2"
    if command -v gum >/dev/null 2>&1; then
        gum style --border normal --margin "1" --padding "0 2" --border-foreground 212 "Step $STEP_NUM: $STEP_DESC"
    else
        echo "=========================================================="
        echo "Step $STEP_NUM: $STEP_DESC"
        echo "=========================================================="
    fi
}

get_env_encoded_name() {
    local prefix="$1"
    local org="$2"
    local env="$3"

    # Calculate short SHA based on "org:env" string
    local sha
    if command -v shasum >/dev/null 2>&1; then
        sha=$(printf "%s" "${org}:${env}" | shasum -a 256 | cut -c1-7)
    else
        sha=$(printf "%s" "${org}:${env}" | sha256sum | cut -c1-7)
    fi

    # Calculate short names (first 15 characters)
    local short_org
    short_org=$(printf "%s" "${org}" | cut -c1-15)
    local short_env
    short_env=$(printf "%s" "${env}" | cut -c1-15)

    echo "${prefix}-${short_org}-${short_env}-${sha}-sa"
}

get_org_encoded_name() {
    local prefix="$1"
    local org="$2"

    # Calculate short SHA based on "org" string
    local sha
    if command -v shasum >/dev/null 2>&1; then
        sha=$(printf "%s" "${org}" | shasum -a 256 | cut -c1-7)
    else
        sha=$(printf "%s" "${org}" | sha256sum | cut -c1-7)
    fi

    # Calculate short name (first 15 characters)
    local short_name
    short_name=$(printf "%s" "${org}" | cut -c1-15)

    echo "${prefix}-${short_name}-${sha}-sa"
}

check_prereqs() {
    log "Checking prerequisites..."
    command -v gcloud >/dev/null 2>&1 || error "gcloud is required but not installed."
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required but not installed."
    command -v helm >/dev/null 2>&1 || error "helm is required but not installed."
    command -v curl >/dev/null 2>&1 || error "curl is required but not installed."
    
    if ! command -v gum >/dev/null 2>&1; then
        echo "[INFO] 'gum' not found. Installing 'gum' for visual tracking..."
        if command -v apt >/dev/null 2>&1; then
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -yes -o /etc/apt/keyrings/charm.gpg
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
            sudo apt update -y && sudo apt install gum -y || warn "Failed to install gum."
        else
            warn "apt not found, skipped gum installation. Execution will proceed without visuals."
        fi
    fi
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

    local missing_sa=0
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
            --env prod \
            --dir ./service-accounts

        # Build a wrapper script to pipe 'y' to the tool to handle its interactive prompts
        cat << 'EOF' > ./create_sas_wrapper.sh
#!/bin/bash
yes | ./apigee-operator/etc/tools/create-service-account \
    --env prod \
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
setup_workload_identity() {
    log "Setting up Workload Identity bindings for GSA -> KSA..."
    bind_wif() {
        local SA_NAME=$1
        local KSA_NAME=$2
        run_with_spin "Binding $SA_NAME to KSA $KSA_NAME" gcloud iam service-accounts add-iam-policy-binding \
            "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
            --role roles/iam.workloadIdentityUser \
            --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${APIGEE_NAMESPACE}/${KSA_NAME}]"
    }

    # Org and env scoped wif bindings
    bind_wif "apigee-mart" "$(get_org_encoded_name "apigee-mart" "$APIGEE_ORG")"
    bind_wif "apigee-mart" "$(get_org_encoded_name "apigee-connect-agent" "$APIGEE_ORG")"
    bind_wif "apigee-synchronizer" "$(get_env_encoded_name "apigee-synchronizer" "$APIGEE_ORG" "$APIGEE_ENV")"
    bind_wif "apigee-runtime" "$(get_env_encoded_name "apigee-runtime" "$APIGEE_ORG" "$APIGEE_ENV")"
    bind_wif "apigee-watcher" "$(get_org_encoded_name "apigee-watcher" "$APIGEE_ORG")"
    bind_wif "apigee-mint-task-scheduler" "$(get_org_encoded_name "apigee-mint-task-scheduler" "$APIGEE_ORG")"
    
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
        local ERR_OUT
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
                local ERR_OUT
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
  # Set to false for single region installations and  for multi-region
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
        local CMD_OUT
        CMD_OUT=$(kubectl create namespace "$APIGEE_NAMESPACE" 2>&1)
        
        if [ $? -eq 0 ]; then
            echo "$CMD_OUT" | awk '{print "    " $0}'
        else
            error "Failed to create namespace '$APIGEE_NAMESPACE'.\nDetails:\n$CMD_OUT"
        fi
    fi
}

# ==========================================
# Main Execution
# ==========================================
main() {
    log "Starting Apigee Hybrid v1.16 GKE Deployment Script..."
    check_prereqs
    
    step 1 "Create a Cluster"
    setup_project
    setup_gke
    
    step "1a" "Create an Apigee hybrid organization"
    create_apigee_organization
    
    step "1b" "Create an external IP address for ingress"
    setup_apigee_external_ip

    step "1c" "Create an environment & env. group"
    create_apigee_environment_and_group
    
    step 2 "Download the Apigee Helm charts"
    download_helm_charts
    
    step 3 "Create the apigee namespace"
    create_apigee_namespace
    
    step 4 "Create service accounts"
    setup_service_accounts
    
    step 5 "Set up service account authentication"
    setup_workload_identity
    
    step 6 "Create TLS certificates"
    setup_networking
    
    step 7 "Create the overrides"
    check_overrides
    
    step 8 "Enable Control Plane access"
    enable_control_plane_access
    
    step 9 "Install cert-manager"
    install_cert_manager
    
    step 10 "Install the Apigee hybrid CRDs"
    install_crds
    
    step 11 "Install Apigee hybrid Using Helm"
    install_apigee_operator
    install_apigee_datastore
    install_apigee_telemetry
    install_apigee_redis
    install_apigee_ingress_manager
    install_apigee_org
    install_apigee_env
    install_apigee_env_group

    log "=========================================================="
    log "Apigee Hybrid Deployment Complete!"
    log "Next steps required for full functionality:"
    log ". Setup Ingress routing/load balancer point."
    log "=========================================================="
}

main

