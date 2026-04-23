# Apigee Hybrid GKE Deployment Script

This repository contains a POSIX-compliant shell script designed to automate the deployment of **Apigee hybrid (v1.16.x)** on **Google Kubernetes Engine (GKE)**. It handles everything from cloud infrastructure provisioning to the installation of Apigee runtime components using Helm.

> [!WARNING]  
> **Non-Production Use Only:** This script is intended for demonstration, experimentation, or Proof of Concept (POC) purposes. It is not architected for production environments.

---

## 🚀 Overview

The script automates a multi-step process to get an Apigee environment up and running:
1.  **Infrastructure:** Sets up a GKE Standard cluster with dedicated node pools for data and runtime.
2.  **Management Plane:** Creates the Apigee Organization, Environment, and Environment Group.
3.  **Security:** Provisions Google Service Accounts (GSA) and configures **Workload Identity Federation** for secure communication between GKE and Google APIs.
4.  **Components:** Installs Cert-Manager, Apigee CRDs, and all hybrid components (Cassandra, Redis, Ingress, etc.) via Helm.

---

## 📋 Prerequisites

Before running the script, ensure you have the following tools installed:
* `gcloud` CLI
* `kubectl`
* `helm` (v3+)
* `openssl` & `curl`
* *Optional:* `gum` (the script will attempt to install it for a better visual experience).

### Google Cloud Permissions
The execution account must have **Owner** and **Apigee Organization Admin** roles on the target project.

### Organization Policies
Ensure the following constraints are **Inactive** in your Google Cloud Console to allow the script to operate:
* `iam.disableServiceAccountKeyCreation`
* `compute.vmExternalIpAccess`
* `compute.requireShieldedVm`

---

## ⚙️ Configuration

You can customize the deployment by creating a `.env` file in the same directory or by editing the variables directly in the script:

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `PROJECT_ID` | `my-apigee-project` | Your GCP Project ID |
| `CLUSTER_REGION` | `europe-west1` | Region for GKE and resources |
| `APIGEE_ENV` | `test` | Name of the Apigee environment |
| `APIGEE_VERSION` | `1.16.0` | Target Apigee hybrid version |
| `OVERRIDES_FILE` | `overrides.yaml` | Name of the Helm overrides file |

---

## 🛠️ How to Use

1.  **Clone the repository** and navigate to the folder.
2.  **Make the script executable**:
    ```bash
    chmod +x deploy_apigee_hybrid.sh
    ```
3.  **Run the deployment**:
    ```bash
    ./deploy_apigee_hybrid.sh
    ```

The script will automatically check for prerequisites, prompt for missing installations if possible, and guide you through each step with visual progress indicators.

---

## 🏗️ Technical Highlights

* **Workload Identity:** The script avoids using static Service Account keys where possible, favoring GKE Workload Identity for enhanced security.
* **Node Pool Separation:** It creates specific node pools (`apigee-data` and `apigee-runtime`) to ensure Cassandra and the Runtime traffic are isolated for better stability.
* **Automated Networking:** It reserves a static external IP and generates a self-signed certificate for `nip.io` to allow immediate testing of the ingress gateway.
* **Storage:** A custom SSD-backed StorageClass (`apigee-sc`) is created specifically for Cassandra to meet performance requirements.

---

## 🏁 Next Steps

Once the script completes successfully:
1.  Verify the status of your pods: `kubectl get pods -n apigee`.
2.  Check the Apigee UI in the Google Cloud Console to confirm the environment is "Active".
3.  Configure your API Proxies and start testing!
