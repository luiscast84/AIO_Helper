@lab.Title
Welcome to the Lab, **@lab.User.FirstName!**

This Lab will guide you through the steps to deploy Azure IoT Operations on an Ubuntu 22.04 LTS machine from scratch.

### Log In to the Virtual Machine.

Please, launch the VM and Login with the following credentials...

**Username: ++@lab.VirtualMachine(UbuntuDesktop(22.04)).Username++**

**Password: +++@lab.VirtualMachine(UbuntuDesktop(22.04)).Password+++**

Remember that you can use the icons on top left to automatically type the password.

***

## **Module 1 - Get familiar with the lab environment**

Welcome to your new Ubuntu 22.04 environment.

Every command you need to type in the terminal has a checkbox you need to mark to progress on the completion. Please, click on the checkbox below:

- [ ] **Checkbox demo**

Well done! Let's continue describing the main tool of development. This LAB460 will use Visual Studio Code as the conductor tool for the different modules. 

Please, open Visual Studio Code:

!IMAGE[edgebrowser.png](instructions277358/edgebrowser.png)

> [!help]If after opening VS Code it asks for the password to unblock the session, please click here: +++@lab.VirtualMachine(UbuntuDesktop(22.04)).Password+++:

!IMAGE[authentication.png](instructions277358/authentication.png)

### Environment information

> [!knowledge] This Ubuntu environment has a pre-synced repository with code and resources you will follow during this Lab. A Setup Environment script was already deployed and configured the system with the following components:
>
> * K3s as the Kubernetes distribution
> * Helm client
> * Installed all the azure dependencies and pre-requisites (connectedClusters)
> * Configuration and optimization of K3s regarding file descriptors and inotify
> * Some tools have been also preinstalled for you:
> * System updates
> * Visual Studio Code
> * Git
> * k3s
> * Azure Cli and extensions
> * MQTT Explorer
> * K9s

Please continue to the next Module: Azure Arc onboarding of the Kubernetes cluster!

***

## **Module 2 - Arc-enable the Kubernetes cluster and deploy azure resources and dependencies**

### In this module, you will:

* Execute a Script to automate the Arc onboarding of your Kubernetes Cluster
* Register all the Resource Providers if not present
* Enable custom locations and extended locations features for Arc-enabled Kubernetes
* Retrieve information for existent resources: Azure KeyVault and Azure Storage Account
* Generate all variables for this lab and export them:
    * @lab.Variable(Subscription_Id)
    * @lab.Variable(Resource_Group)
    * @lab.Variable(Location)
    * @lab.Variable(Cluster_Name)
    * @lab.Variable(Custom_Locations_ObjectID)
    * @lab.Variable(K3s_Issuer_URL)
    * @lab.Variable(Azure_KeyVault_Name)
    * @lab.Variable(Azure_KeyVault_ID)
    * @lab.Variable(Storage_Account_Name)
    * @lab.Variable(Storage_Account_ID)


> [!note] The following Azure Resource Providers are registered in the background when the Lab is launched. Please, take into account if the proccess didn't finish it can take several minutes to complete. The script will take care of this step too:
* az provider register -n "Microsoft.ExtendedLocation"
* az provider register -n "Microsoft.Kubernetes"
* az provider register -n "Microsoft.KubernetesConfiguration"
* az provider register -n "Microsoft.IoTOperations"
* az provider register -n "Microsoft.DeviceRegistry"
* az provider register -n "Microsoft.SecretSyncController"

### Instructions

1. From the same terminal window in VSCode, please type this in the embedded terminal:

!IMAGE [RunAzure_ResourcesfromTerminal.png](instructions277358/RunAzure_ResourcesfromTerminal.png)

- [ ] `chmod +x Setup_AzureResources.sh`

- [ ]`./Setup_AzureResources.sh`

Please input `@lab.VirtualMachine(UbuntuDesktop(22.04)).Password` when prompted by the script, **and click intro** since it won't display in the terminal:

!IMAGE [PutPasswordScript.png](instructions277358/PutPasswordScript.png)

2. When prompted to authenticate in Azure, use the provided username and password from the Resources tab of the instruction pane.

!IMAGE [azureauthentication.png](instructions277358/azureauthentication.png)

**Azure Username:** `@lab.CloudPortalCredential(User1).Username`

**Azure Password:** `@lab.CloudPortalCredential(User1).Password`

Once you authenticate and close the browser window, please, check the terminal and type "1" to select your default subscription in the demo tenant.

!IMAGE [az_login.png](instructions277358/az_login.png)

3. Confirm all the proposed actions:

!IMAGE [az_login.png](instructions277358/Continuetoonboard.png)

You should get a result similar to the following image:

!IMAGE [resutlsofazureenablement.png](instructions277358/resutlsofazureenablement.png)

> [!alert] Please note this process can take around 10 minutes to complete. Do not cancel and ask for assistance if you get a different result.

* Let's go now to Azure Portal to check how the Arc enabled cluster is now visible in the Resource Group:

!IMAGE[rg460.png](instructions277358/rg460.png)

> [!hint] Open Edge Browser and navigate to <knowledge[Azure Portal - Resource Groups](https://portal.azure.com/#browse/resourcegroups). Skip or cancel all the "first-time" wizards when loggin into Azure Portal and navigate to **Resource Groups**

> [!help] If prompted for cloud credentials again:

**Azure Username:** `@lab.CloudPortalCredential(User1).Username`

**Azure Password:** `@lab.CloudPortalCredential(User1).Password`

* Select the only Resource Group available and check the results: Your new arc enabled kubernetes cluster listed as **Kubernetes - Azure Arc**

!IMAGE [Arcenabledportal.png](instructions277358/Arcenabledportal.png)

Let's continue now to the next module: Configuration and deployment of Azure IoT Operations.

***

## **Module 3 - Deploy Azure IoT Operations**

> [!knowledge] [Azure IoT Operations](https://learn.microsoft.com/en-us/azure/iot-operations/get-started-end-to-end-sample/quickstart-deploy "Azure IoT Operations") is a suite of data services that run on Kubernetes clusters. You want these clusters to be managed remotely from the cloud, and able to securely communicate with cloud resources and endpoints. 

**1. As a continuation of the previous step, let's make all the enviroment variables available for the following steps in the lab:**
Please type the following in the builtin terminal in Visual Studio Code:

- [ ] `source azure_config.env`

You can check all the variables here: 

- [ ] `cat azure_config.env`

!IMAGE [test_env.png](instructions277358/test_env.png)

**2. Install de CLI extension for Azure IoT Operations (AIO):**

- [ ] `az extension add --upgrade --name azure-iot-ops`

!IMAGE [iot-ops-extension.png](instructions277358/iot-ops-extension.png)

**3. Verify that the host is ready:**

- [ ] `az iot ops check`

!IMAGE[aio_checknew.png](instructions277358/aio_checknew.png)

**4. Create and export an Schema Registry for Azure IoT Operations:**
> [!knowledge] Schemas are documents that describe the format of a message and its contents to enable processing and contextualization. The schema registry is a synchronized repository in the cloud and at the edge. The schema registry stores the definitions of messages coming from edge assets, and then exposes an API to access those schemas at the edge. The schema registry is backed by a cloud storage account. This storage account was pre-created as part of the lab setup.

Create a namespace for your schema registry namespace. The namespace uniquely identifies a schema registry within a tenant:

- [ ] `export SCHEMA_REGISTRY_NAMESPACE="schenmans@lab.LabInstance.GlobalId"`

Create a schema registry that connects to your storage account. This command also creates a blob container called schemas in the storage account if one doesn't exist already:

- [ ]` az iot ops schema registry create --name "schema@lab.LabInstance.GlobalId" --resource-group @lab.Variable(Resource_Group) --registry-namespace $SCHEMA_REGISTRY_NAMESPACE --sa-resource-id @lab.Variable(Storage_Account_ID)`

Save the Schema Registry Resource ID:

- [ ]` export SCHEMA_REGISTRY_RESOURCE_ID=$(az iot ops schema registry show --name schema@lab.LabInstance.GlobalId --resource-group @lab.Variable(Resource_Group) -o tsv --query id)`

**5. Install foundational services for Azure IoT Operations**

Now you can initialize the cluster for the AIO services. This command will take a few minutes to complete.

- [ ] `az iot ops init --cluster @lab.Variable(Cluster_Name) --resource-group @lab.Variable(Resource_Group)`

> [!alert] Please note this process can take around 10 minutes to complete.

!IMAGE [IotOpsInit.png](instructions277358/IotOpsInit.png)

**6. Deploy AIO in the cluster:**

- [ ] `az iot ops create --name aio-lab460 --cluster @lab.Variable(Cluster_Name) --resource-group @lab.Variable(Resource_Group) --sr-resource-id $SCHEMA_REGISTRY_RESOURCE_ID --enable-rsync true --add-insecure-listener true`

> [!alert] Please note this process can take more than 15 minutes to complete.

!IMAGE [aio_deploy_result.png](instructions277358/aio_deploy_result.png)

Now, let's check the pods for Azure IoT Operations are running in the cluster with the following command:

- [ ] `kubectl get pods -n azure-iot-operations`

!IMAGE [aio_pods.png](instructions277358/aio_pods.png)

And as well in Azure Portal:

!IMAGE [aio_portal.png](instructions277358/aio_portal.png)

**7. Enable secure settings:**

**Set up user-assigned managed identity for Azure IoT Components**

Secrets Management for Azure IoT Operations uses Secret Store extension to sync the secrets from an Azure Key Vault and store them on the edge as Kubernetes secrets.

- [ ] `export USER_ASSIGNED_MI_NAME="useraminame@lab.LabInstance.GlobalId"`

- [ ] `az identity create --name $USER_ASSIGNED_MI_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --subscription $SUBSCRIPTION_ID`

Get the resource ID of the user-assigned managed identity:
- [ ] `export USER_ASSIGNED_MI_RESOURCE_ID=$(az identity show --name $USER_ASSIGNED_MI_NAME --resource-group $RESOURCE_GROUP --query id --output tsv)`

Enable secret synchronization:
- [ ] `az iot ops secretsync enable --instance "aio-lab460" --resource-group $RESOURCE_GROUP --mi-user-assigned $USER_ASSIGNED_MI_RESOURCE_ID --kv-resource-id @lab.Variable(Azure_KeyVault_ID)`

**Set up user-assigned managed identity for cloud connections**

Some Azure IoT Operations components like dataflow endpoints use user-assigned managed identity for cloud connections. It's recommended to use a separate identity from the one used to set up Secrets Management.

1. Create a User Assigned Managed Identity which will be used for cloud connections.

- [ ] `export CLOUD_ASSIGNED_MI_NAME="cloudami@lab.LabInstance.GlobalId"`

- [ ] `az identity create --name $CLOUD_ASSIGNED_MI_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --subscription $SUBSCRIPTION_ID`

Get the resource ID of the user-assigned managed identity:

- [ ] `export CLOUD_ASSIGNED_MI_RESOURCE_ID=$(az identity show --name $CLOUD_ASSIGNED_MI_NAME --resource-group $RESOURCE_GROUP --query id --output tsv)`

2. Use the az iot ops identity assign command to assign the identity to the Azure IoT Operations instance. This command also creates a federated identity credential using the OIDC issuer of the indicated connected cluster and the Azure IoT Operations service account.

- [ ] `az iot ops identity assign --name "aio-lab460" --resource-group $RESOURCE_GROUP --mi-user-assigned $CLOUD_ASSIGNED_MI_RESOURCE_ID`

**8. Check MQTT broker and deploy a data Simulator:**

We can use a local MQTT client to easily check that messages are being sent to the AIO MQ broker. First let's identity the service where the MQ broker is listening. Run the following command.

- [ ] `kubectl get services -n azure-iot-operations`

!IMAGE [mqttloadbalancer.png](instructions277358/mqttloadbalancer.png)

> [!note] Please note the **aio-broker-insecure** service for enabling the internal communication with the MQTT broker on port 1883.

Deploy a workload that will simulate industrial assets and send data to the MQ Broker.

- [ ] `kubectl apply -f simulator.yaml`

!IMAGE [simulatordeployment.png](instructions277358/simulatordeployment.png)

**9. Check topics with MQTT Explorer**

Go to the favourites bar and click the MQTT Explorer icon to open it, and click con **Connect** as indicated in the image. We can use this program to check the contents of the MQTT Broker.

!IMAGE[mqttconfig.png](instructions277358/mqttconfig.png)

MQTT uses MQTT Topics to organize messages. An MQTT topic is like an address used by the protocol to route messages between publishers and subscribers. Think of it as a specific channel or path where devices can send (publish) and receive (subscribe to) messages. Each topic can have multiple levels separated by slashes, such as home/livingroom/temperature, to organize data more effectivelycan be published to specific topics.

Our simulator is publishing messages to the **"iot/devices" topic** prefix. You can drill down through the topics to view incoming MQ messages written by the devices to specific MQTT topics.

!IMAGE [podinmqttexplorer.png](instructions277358/podinmqttexplorer.png)

> [!knowledge] Azure IoT Operations publishes its own self test messages to the azedge topic. This is useful to confirm that the MQ Broker is available and receiving messages.

***

## **Module 4 - Transform Data at Scale with Azure IoT Operations**

In this module you will learn the following skills:

* Learn about the Digital Operations Experience portal (DOE).
* How to use Dataflows to contextualize and send data edge to cloud.
* Deployment options and examples.

**Digital Operations Experience**

As part of the Operational Technology rol, Azure IoT Operations has dedicated portal where monitor and manage **Sites** and data transformations with **Dataflows**.

**Sites**

Azure Arc site manager allows you to manage and monitor your on-premises environments as **Azure Arc sites**. Arc sites are scoped to an Azure resource group or subscription and enable you to track connectivity, alerts, and updates across your environment. The experience is tailored for on-premises scenarios where infrastructure is often managed within a common physical boundary, such as a store, restaurant, or factory.

Please, click on View unassigned instances:

!IMAGE[Sites.png](instructions277358/Sites.png)

And select your instance from the list:

!IMAGE[Sites2.png](instructions277358/Sites2.png)

In this screen, you can check monitoring metrics of the Arc enabled cluster in Sites. Now, let's move to Dataflows on the left panel:

!IMAGE[Sites3.png](instructions277358/Sites3.png)

**Dataflows**

Dataflows is a built-in feature in Azure IoT Operations that allows you to connect various data sources and perform data operations, simplifying the setup of data paths to move, transform, and enrich data.
As part of Dataflows, Data Processor can be use to perform on-premises transformation in the data either by using Digital Opeartions Experience or via automation.

The configuration for a Dataflow can be done by means of different methods:
* With Kubernetes and Custom Resource Definitions (CRDs). Changes are only applyed on-prem and don't sync with DOE.
* Via Bicep automation: Changes are deployed on the Schema Registry and are synced to the edge. (Deployed Dataflows are visible on DOE).
* Via DOE: Desig your Dataflows and Data Processor Transformations with the UX and synch changes to the edge to perform on-prem contextualization.

You can write configurations for various use cases, such as:

* Transform data and send it back to MQTT
* Transform data and send it to the cloud
* Send data to the cloud or edge without transformation


By unsing DOE and the built in Dataflows interface:

!IMAGE[Dataflows1.png](instructions277358/Dataflows1.png)

You can create a new Dataflows selecting the Source, transforming data and selecting the dataflow endpoint:

!IMAGE[df2.png](instructions277358/df2.png)

For the sake of the time and to reduce complexity during this lab, we will generate this dataflows by Bicep automation. This automation will:

* Select a topic from the MQTT simulator we deployed on previous steps

* Send topic data to Event Hub

**1. To send the data to Event Hub, we need to retrieve some information on the resources already deployed in your resource group as a pre-requisite:**

* EventHub Namespace:

- [ ] `export eventHubNamespace=$(az eventhubs namespace list --resource-group $RESOURCE_GROUP --query '[].name' -o tsv)`

* EventHub Namespace ID:

- [ ] `export eventHubNamespaceId=$(az eventhubs namespace show --name $eventHubNamespace --resource-group $RESOURCE_GROUP --query id -o tsv)`

* EventHub Hostname:

- [ ] `export eventHubNamespaceHost="${eventHubNamespace}.servicebus.windows.net:9093"`

**2. Azure IoT Operations needs to publish and subscribe to this EventHub so we need to grant permissions on the service principal for the MQTT Broker in charge of this task:**

* Retrieving IoT Operations extension Service Principal ID:

- [ ] `export iotExtensionPrincipalId=$(az k8s-extension list --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME --cluster-type connectedClusters --query "[?extensionType=='microsoft.iotoperations'].identity.principalId" -o tsv)`

* Assigning Azure Event Hubs **Data Sender** role to EventHub Namespace:

- [ ] `az role assignment create --assignee $iotExtensionPrincipalId --role "Azure Event Hubs Data Sender" --scope $eventHubNamespaceId`

* Assigning Azure Event Hubs **Data Receiver** role to EventHub Namespace:

- [ ] `az role assignment create --assignee $iotExtensionPrincipalId --role "Azure Event Hubs Data Receiver" --scope $eventHubNamespaceId`

**3. In addition to this, we also need the Custom Locations name and the eventHub in the EventHub Namespace as the parameter of the Bicep file containing the dataflows automation:**

* Get CustomLocationName in a Resource Group:

- [ ] `export customLocationName=$(az resource list --resource-group $RESOURCE_GROUP --resource-type "Microsoft.ExtendedLocation/customLocations" --query '[].name' -o tsv)`

* List all Event Hubs in a specific namespace:

- [ ] `export eventHubName=$(az eventhubs eventhub list --resource-group $RESOURCE_GROUP --namespace-name $eventHubNamespace --query '[].name' -o tsv)`

* Deploy Dataflows:

- [ ] `export dataflowBicepTemplatePath="dataflows.bicep"`

- [ ] `az deployment group create --resource-group $RESOURCE_GROUP --template-file $dataflowBicepTemplatePath --parameters aioInstanceName="aio-lab460" eventHubNamespaceHost=$eventHubNamespaceHost eventHubName=$eventHubName customLocationName=$customLocationName`

**4. Check your Dataflows deployment:**

* In DOE and Dataflows:

Please go to the DOE instance and check your new Dataflows:

!IMAGE[dataflows.png](instructions277358/dataflows.png)

* Select the dataflows deployed via Bicep configuration:

!IMAGE[dataflows2eh.png](instructions277358/dataflows2eh.png)

* Please go to your Resource Group in Azure Portal and navigate to your **EventHub Namespaces**. Then click on **Data Explorer** and select:

!IMAGE[dataflows3.png](instructions277358/dataflows3.png)

You can see the data flowing from your Azure IoT Operations instance!

#**CONGRATULATIONS! You have succesfully ended this LAB 460: Transforming Industries with Azure IoT, AI, Edge & Operational Excellence.**#