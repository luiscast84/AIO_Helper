#!/bin/bash
az extension add --upgrade --name azure-iot-ops

az iot ops verify-host

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