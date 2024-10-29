#!/bin/bash
sudo apt-get update && sudo sudo apt-get dist-upgrade --assume-yes

#Install VS-Code
echo "code code/add-microsoft-repo boolean true" | sudo debconf-set-selections


sudo apt-get install apt-transport-https ca-certificates curl gnupg lsb-release
sudo mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc |   gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
AZ_DIST=$(lsb_release -cs)
echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" | sudo tee /etc/apt/sources.list.d/azure-cli.sources
sudo apt-get update
sudo apt-get install azure-cli

az extension add --upgrade --name azure-iot-ops
az extension add --upgrade --name connectedk8s

curl -sfL https://get.k3s.io | sh -
sudo apt-get update
# apt-transport-https may be a dummy package; if so, you can skip that package
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
# If the folder `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
# sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg # allow unprivileged APT programs to read this keyring
# This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list   # helps tools such as command-not-found to work correctly
sudo apt-get update
sudo apt-get install -y kubectl

curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

mkdir ~/.kube
sudo KUBECONFIG=~/.kube/config:/etc/rancher/k3s/k3s.yaml kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config
chmod  0600 ~/.kube/config
export KUBECONFIG=~/.kube/config
#switch to k3s context
kubectl config use-context default
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

echo fs.file-max = 100000 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

az login
az provider register -n "Microsoft.ExtendedLocation"
az provider register -n "Microsoft.Kubernetes"
az provider register -n "Microsoft.KubernetesConfiguration"
az provider register -n "Microsoft.IoTOperations"
az provider register -n "Microsoft.DeviceRegistry"
az provider register -n "Microsoft.SecretSyncController"
export SUBSCRIPTION_ID= "Your Sub"
# Azure region where the created resource group will be located
export LOCATION="Your location"
# Name of a new resource group to create which will hold the Arc-enabled cluster and Azure IoT Operations resources
export RESOURCE_GROUP="Your RG name"
# Name of the Arc-enabled cluster to create in your resource group
export CLUSTER_NAME="Your cluster name in lowercaps"
az connectedk8s connect --name $CLUSTER_NAME -l $LOCATION --resource-group $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID --enable-oidc-issuer --enable-workload-identity
export ISSUER_URL_ID=$(az connectedk8s show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl --output tsv)

#Enabling Service Account in k3s:
{
  echo "kube-apiserver-arg:"
  echo " - service-account-issuer=$ISSUER_URL_ID"
  echo " - service-account-max-token-expiration=24h"
} | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null


export OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
az connectedk8s enable-features -n $CLUSTER_NAME -g $RESOURCE_GROUP --custom-locations-oid $OBJECT_ID --features cluster-connect custom-locations

systemctl restart k3s
az iot ops verify-host

az keyvault create --enable-rbac-authorization --name $AKV_NAME --resource-group $RESOURCE_GROUP
export AKV_ID= "The ID you get in this step"

az extension add --upgrade --name azure-iot-ops
az storage account create --name $STORAGE_NAME --resource-group $RESOURCE_GROUP --enable-hierarchical-namespace

az iot ops schema registry create --name $SCHEMAREG_NAME --resource-group $RESOURCE_GROUP --registry-namespace $STORAGE_NAME --sa-resource-id $(az storage account show --name STORAGE_NAME --resource-group $RESOURCE_GROUP -o tsv --query id)
export SCHEMA_REGISTRY_RESOURCE_ID= "The ID you get in this step"

az iot ops init --cluster $CLUSTER_NAME --resource-group $RESOURCE_GROUP --sr-resource-id $SCHEMA_REGISTRY_RESOURCE_ID

az iot ops create --name $AIO_DEPLOYMENT_NAME --cluster $CLUSTER_NAME --resource-group $RESOURCE_GROUP --enable-rsync true --add-insecure-listener true
az identity create --name $USERASSIGNED_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --subscription $SUBSCRIPTION_ID
export USERASSIGNED_ID= "The ID you get in this step"

az iot ops secretsync enable --name $AIO_DEPLOYMENT_NAME --resource-group $RESOURCE_GROUP --mi-user-assigned $USERASSIGNED_ID --kv-resource-id $AKV_ID
az identity create --name $CLOUDASSIGNED_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --subscription $SUBSCRIPTION_ID
export CLOUDASSIGNED_ID= "The ID you get in this step"

az iot ops identity assign --name $AIO_DEPLOYMENT_NAME --resource-group $RESOURCE_GROUP --mi-user-assigned $CLOUDASSIGNED_ID