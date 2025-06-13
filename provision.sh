#!/bin/bash
set -e

# --- Script Setup ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# --- Configuration ---
CLUSTER_NAME="crossplane-demo"
KIND_CONFIG="${SCRIPT_DIR}/kind-cluster.yaml"
AWS_CREDS_FILE="${HOME}/.aws/credentials"
K8S_AWS_SECRET_NAME="aws-secret"
CROSSPLANE_NAMESPACE="crossplane-system"
CROSSPLANE_HELM_VERSION="1.16.0"
AWS_REGION="ap-southeast-2"

# --- Pre-flight Checks ---
if ! command -v aws &> /dev/null; then echo -e "${RED}ERROR: aws CLI not found.${NC}"; exit 1; fi
if ! command -v kind &> /dev/null; then echo -e "${RED}ERROR: kind not found.${NC}"; exit 1; fi
if ! command -v helm &> /dev/null; then echo -e "${RED}ERROR: helm not found.${NC}"; exit 1; fi

# --- Functions ---
function create_cluster() {
    echo -e "${GREEN}### Step 1: Creating Kind Cluster... ###${NC}"
    if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
    else
        echo -e "${YELLOW}Kind cluster already exists. Skipping.${NC}"
    fi
}
function install_crossplane() {
    echo -e "\n${GREEN}### Step 2: Installing Crossplane... ###${NC}"
    if ! helm status crossplane -n "${CROSSPLANE_NAMESPACE}" &> /dev/null; then
        helm repo add crossplane-stable https://charts.crossplane.io/stable; helm repo update
        helm install crossplane --namespace "${CROSSPLANE_NAMESPACE}" --create-namespace crossplane-stable/crossplane --version "${CROSSPLANE_HELM_VERSION}" --wait
    else
        echo -e "${YELLOW}Crossplane is already installed. Skipping.${NC}"
    fi
}
function configure_aws_provider() {
    echo -e "\n${GREEN}### Step 3: Configuring AWS Provider... ###${NC}"
    if [ ! -f "${AWS_CREDS_FILE}" ]; then echo "AWS credentials not found"; exit 1; fi
    
    # Apply credentials first
    kubectl create secret generic "${K8S_AWS_SECRET_NAME}" -n "${CROSSPLANE_NAMESPACE}" --from-file=creds="${AWS_CREDS_FILE}" --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply the provider package definition
    kubectl apply -f "${SCRIPT_DIR}/crossplane/00-provider.yaml"

    echo "Waiting 30s for initial provider pods to appear..."
    sleep 30

    echo "Forcing a restart of the provider pods to ensure clean initialization..."
    kubectl delete pods -n "${CROSSPLANE_NAMESPACE}" -l "pkg.crossplane.io/provider=provider-aws-s3" --ignore-not-found=true
    
    echo "Waiting for Provider package to become healthy..."
    # This wait is now more reliable as it's for the restarted pods
    kubectl wait "provider.pkg.crossplane.io/provider-aws-s3" --for=condition=Healthy --timeout=5m
    
    # Apply the provider config
    kubectl apply -f "${SCRIPT_DIR}/crossplane/01-providerconfig.yaml"
    
    echo -e "${GREEN}AWS Provider is fully configured and healthy.${NC}"
}
function provision_resources() {
    # The rest of the script remains the same as the working direct-resource version
    echo -e "\n${GREEN}### Step 4: Provisioning AWS Resources Directly... ###${NC}"
    
    kubectl create -f "${SCRIPT_DIR}/crossplane/02-s3.yaml"
    #kubectl wait buckets.s3.aws.upbound.io -l app=my-s3-bucket --for=condition=Ready=True --timeout=2m
    
    echo -e "\n${GREEN}--- PROVISIONING COMPLETE ---${NC}"
}
function cleanup() {
    # ...
    echo -e "\n${GREEN}### Cleaning up all resources... ###${NC}"
    BUCKET_NAME=$(kubectl get buckets -o custom-columns=NAME:.metadata.name --no-headers | grep '^crossplane-bucket-')
    kubectl delete bucket $BUCKET_NAME --ignore-not-found=true
    sleep 5
    deleteKindCluster
    echo -e "${GREEN}Cleanup complete.${NC}"
}
function deleteKindCluster() {
    kind delete cluster --name "${CLUSTER_NAME}"
    rm -f "${SCRIPT_DIR}/crossplane/*-runtime.yaml"
}

# --- Main Execution ---
if [ "$1" == "cleanup" ]; then
    cleanup
else
    create_cluster
    install_crossplane
    configure_aws_provider
    provision_resources
fi