#!/bin/bash
az extension add --upgrade --name azure-iot-ops
az extension add --upgrade --name connectedk8s

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