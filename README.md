# Apigee Hybrid GKE Deployment Script

This repository contains a POSIX-compliant shell script (`deploy_apigee_hybrid.sh`) designed to automate the deployment of **Apigee hybrid (v1.15.x, v1.16.x,v1.17.x+)** on **Google Kubernetes Engine (GKE)**. It handles everything from cloud infrastructure provisioning to the installation of Apigee runtime components using Helm, including optional support for **Apigee Model Context Protocol (MCP)**.

> [!WARNING]  
> **Non-Production Use Only:** This script is intended for demonstration, experimentation, or Proof of Concept (POC) purposes. It is not architected for production environments.

---

## 🚀 Overview

The script automates a multi-step process to get an Apigee environment up and running:
1.  **Infrastructure:** Sets up a GKE Standard cluster with dedicated node pools for data and runtime.
2.  **Management Plane:** Creates the Apigee Organization, Environment, and Environment Group.
3.  **Security:** Provisions Google Service Accounts (GSA) and configures **Workload Identity Federation** for secure communication between GKE and Google APIs.
4.  **Components:** Installs Cert-Manager, Apigee CRDs, and all hybrid components (Cassandra, Redis, Ingress, etc.) via Helm.
5.  **Model Context Protocol (MCP) Support *(Optional)*:** Configures and deploys the in-cluster Apigee MCP data plane and configures Message Processor routing (`enableMcpServer: true`), either during initial cluster deployment or on an existing Apigee hybrid installation.

---

## 📋 Prerequisites

Before running the script, ensure you have the following tools installed:
* `gcloud` CLI
* `kubectl`
* `helm` (v3+)
* `openssl` & `curl`
* *Optional:* `gum` (the script will attempt to install it automatically on Debian/Ubuntu systems for an enhanced interactive visual experience).

### Google Cloud Permissions
The execution account must have **Owner** and **Apigee Organization Admin** roles on the target project.

### Organization Policies
Ensure the following constraints are **Inactive** in your Google Cloud Console to allow the script to operate:
* `constraints/iam.disableServiceAccountKeyCreation`
* `compute.vmExternalIpAccess`
* `compute.requireShieldedVm`

---

## ⚙️ Configuration

You can customize the deployment by editing the `.env` file in the project root directory or by exporting environment variables before running the script:

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `PROJECT_ID` | `apigee-117` | Your Google Cloud Project ID |
| `APIGEE_ORG` | `${PROJECT_ID}` | Apigee Organization name (must match `PROJECT_ID`) |
| `CLUSTER_NAME` | `apigee-hybrid` | Name of the GKE Standard cluster |
| `CLUSTER_REGION` | `europe-west1` | Google Cloud region for GKE and networking resources |
| `GCP_REGION` | `europe-west1` | Apigee analytics & control plane region |
| `APIGEE_ENV` | `test` | Name of the Apigee environment |
| `APIGEE_ENV_GROUP` | `test-group` | Name of the Apigee environment group |
| `APIGEE_VERSION` | `1.17.0` | Target Apigee hybrid version (`1.17.0` or later required for MCP) |
| `OVERRIDES_FILE` | `overrides-${APIGEE_VERSION}.yaml` | Path to the generated/used Helm overrides file |
| `ENABLE_MCP` | `false` | Set to `"true"` to enable Apigee MCP Server by default |
| `CONTROL_PLANE_LOCATION` | *(empty)* | Optional region prefix if your Apigee org uses Data Residency |
| `ENABLE_WEB_TRACKER` | `true` | Starts a local Web UI (`http://127.0.0.1:8080`) to track deployment progress in real time |
| `TRACKER_HOST` | `127.0.0.1` | Bind address for the Web progress tracker server |
| `TRACKER_PORT` | `8080` | HTTP port for the Web progress tracker UI |

---

## 🛠️ How to Use

1. **Make the script executable**:
   ```sh
   chmod +x deploy_apigee_hybrid.sh
   ```

2. **Choose your execution mode**:

   ### A. Interactive Mode (Default)
   Simply run the script without arguments:
   ```sh
   ./deploy_apigee_hybrid.sh
   ```
   * **If an existing Apigee hybrid installation is detected** on the cluster, the script will prompt you to choose between:
     1. **Enable MCP on existing installation only** (fast path without re-running cluster/org setup)
     2. **Run full deployment (with MCP enabled)**
     3. **Run full deployment (without MCP)**
   * **If no existing installation is detected**, the script will ask whether you want to enable Apigee MCP during the full deployment.

   ### B. Command-Line Flags (Non-Interactive / Automation)
   You can pass explicit flags to bypass interactive prompts:

   * **Full Deployment WITH Apigee MCP enabled:**
     ```sh
     ./deploy_apigee_hybrid.sh --enable-mcp
     ```
   * **Full Deployment WITHOUT Apigee MCP:**
     ```sh
     ./deploy_apigee_hybrid.sh --no-mcp
     ```
   * **Enable MCP ONLY on an Existing Apigee Hybrid Installation:**
     ```sh
     ./deploy_apigee_hybrid.sh --enable-mcp-only
     ```
   * **Display Help & Options:**
     ```sh
     ./deploy_apigee_hybrid.sh --help
     ```

---

## 🤖 Apigee Model Context Protocol (MCP) Enablement

The script implements the official [Enable Model Context Protocol (MCP) in Apigee hybrid](https://docs.cloud.google.com/apigee/docs/api-platform/apigee-mcp/enable-mcp) procedure.

Whether you enable MCP during a fresh deployment (`--enable-mcp`) or on an already running cluster (`--enable-mcp-only`), the script automatically executes and verifies the following steps:

1. **Version & Helm Chart Verification:**
   * Confirms that `APIGEE_VERSION` is `1.17.0` or later.
   * Ensures local `apigee-operator/` and `apigee-org/` Helm charts match `APIGEE_VERSION` (automatically pulling them if missing or outdated).
2. **Step 1 — Update `overrides.yaml`:**
   * Adds or updates the top-level `enableMcpServer: true` key in your `OVERRIDES_FILE`.
3. **Step 2 — Grant Control Plane Access (`watcher_identities`):**
   * Grants the `apigee-watcher` Google Service Account (`apigee-watcher@${PROJECT_ID}.iam.gserviceaccount.com`) access to fetch MCP configuration bundles from the Apigee Control Plane by patching `organizations/${APIGEE_ORG}/controlPlaneAccess?update_mask=watcher_identities`.
   * Polls any resulting long-running operation to completion and verifies via `GET controlPlaneAccess` that `watcherIdentities` contains the service account.
4. **Workload Identity Bindings:**
   * Binds `roles/iam.workloadIdentityUser` on the `apigee-watcher` GSA to the Kubernetes ServiceAccounts used by `apigee-watcher` and `apigee-mcp-server`.
5. **Steps 3 & 4 — Helm Chart Upgrades:**
   * Applies the latest Apigee CRDs.
   * Upgrades the `apigee-operator` Helm release first and waits for the `apigee-controller-manager` deployment rollout.
   * Upgrades the `apigee-org` Helm release to provision the in-cluster MCP data plane (`ApigeeDeployment`, `Service`, `HPA`, `Role`, and `RoleBinding`).
6. **Step 5 — End-to-End Verification & Auto-Remediation:**
   * Waits for all `app=apigee-mcp-server` pods to reach `2/2 Running` (`Ready`).
   * Displays the MCP `ApigeeDeployment`, `Service` (`ClusterIP` on ports `443/TCP` and `15021/TCP`), and `HorizontalPodAutoscaler`.
   * Inspects all Message Processor (`app=apigee-runtime`) pods to verify they received the injected `hostAliases` entry (`mcp.apigee.internal` and `<org>.mcp.apigee.internal`).
   * **Auto-Remediation:** If any Message Processor pod is missing the `hostAliases` entry, the script automatically deletes the `apigee-runtime` pods so the `ApigeeDeployment` controller re-renders them with the updated spec, and waits for them to become `Ready`.

---

## 🏗️ Technical Highlights

* **Strict POSIX Compliance:** Written in standard POSIX `sh` (`#!/bin/sh`) for maximum portability across Linux/Unix environments.
* **Workload Identity:** Avoids static Service Account keys where possible, favoring GKE Workload Identity for enhanced security.
* **Node Pool Separation:** Creates dedicated node pools (`apigee-data` and `apigee-runtime`) so stateful Cassandra workloads and stateless Runtime/MCP traffic are isolated.
* **Automated Networking:** Reserves a static external IP and generates a self-signed certificate for `*.nip.io` to allow immediate testing of the ingress gateway.
* **Storage:** Creates a custom SSD-backed StorageClass (`apigee-sc`) specifically for Cassandra performance requirements.

---

## 🏁 Next Steps

Once the deployment completes successfully:
1. Verify the status of your pods in the `apigee` namespace:
   ```sh
   kubectl get pods -n apigee
   ```
2. Check the Apigee UI in the Google Cloud Console to confirm the environment status is **Active**.
3. If you enabled **MCP**, you can now deploy your first MCP Discovery Proxy by following the [Apigee MCP quickstart](https://docs.cloud.google.com/apigee/docs/api-platform/apigee-mcp/apigee-mcp-quickstart).

