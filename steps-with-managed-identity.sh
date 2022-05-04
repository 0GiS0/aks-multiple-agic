# Variables
RESOURCE_GROUP="aks-multiple-agic-demo"
LOCATION="northeurope"
AKS_NAME="aks-multiple-agic-demo"
VNET_NAME="aks-vnet"
AKS_SUBNET="aks-subnet"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION
RESOURCE_GROUP_ID=$(az group show --name $RESOURCE_GROUP --query id -o tsv)


# Create a virtual network and a subnet for the AKS
az network vnet create \
--resource-group $RESOURCE_GROUP \
--name $VNET_NAME \
--address-prefixes 10.0.0.0/8 \
--subnet-name $AKS_SUBNET \
--subnet-prefix 10.10.0.0/16

# Get VNET id
SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP -n $AKS_SUBNET --vnet-name $VNET_NAME --query id -o tsv)

# Create a user identity for the AKS
az identity create --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP

# Get managed identity ID
IDENTITY_ID=$(az identity show --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP --query clientId -o tsv)

# Create the AKS cluster
az aks create \
--resource-group $RESOURCE_GROUP \
--name $AKS_NAME \
--node-vm-size Standard_B4ms \
--network-plugin azure \
--vnet-subnet-id $SUBNET_ID \
--docker-bridge-address 172.17.0.1/16 \
--dns-service-ip 10.2.0.10 \
--service-cidr 10.2.0.0/24 \
--enable-managed-identity \
--assign-identity $IDENTITY_ID

# Assign the roles needed for Azure AD pod Identity to the user managed identity:  https://azure.github.io/aad-pod-identity/docs/getting-started/role-assignment/

#AKS cluster with managed identity	
KUBELET_CLIENT_ID=$(az aks show -g $RESOURCE_GROUP -n $AKS_NAME --query identityProfile.kubeletidentity.clientId -o tsv)

# Get Node resource group name
NODE_RESOURCE_GROUP=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query nodeResourceGroup -o tsv)
NODE_RESOURCE_GROUP_ID=$(az group show --name $NODE_RESOURCE_GROUP --query id -o tsv)

# Performing role assignments 
az role assignment create --role "Managed Identity Operator" --assignee $KUBELET_CLIENT_ID --scope $NODE_RESOURCE_GROUP_ID
az role assignment create --role "Virtual Machine Contributor" --assignee $KUBELET_CLIENT_ID --scope $NODE_RESOURCE_GROUP_ID

# User-assigned identities that are not within the node resource group 
az role assignment create --role "Managed Identity Operator" --assignee $KUBELET_CLIENT_ID --scope $RESOURCE_GROUP_ID

az role assignment list --assignee $KUBELET_CLIENT_ID -o table --all

##########################################
##### Create Dev Application Gateway ####
##########################################

APPGW_SUBNET="appgw-subnet"

## Create subnet for application gateway
az network vnet subnet create \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--name $APPGW_SUBNET \
--address-prefixes 10.20.0.0/16

### Application Gateway for dev ###
APP_GW_DEV_NAME="app-gw-dev"

# Create public ip
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_DEV_NAME-public-ip \
--allocation-method Static \
--sku Standard

# Create the app gateway
az network application-gateway create \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_DEV_NAME \
--location $LOCATION \
--vnet-name $VNET_NAME \
--subnet $APPGW_SUBNET \
--public-ip-address $APP_GW_DEV_NAME-public-ip \
--sku WAF_v2 \
--capacity 1 

######################################
######## Configure AGIC for dev ######
######################################

# Configure AGIC for dev
# https://azure.github.io/application-gateway-kubernetes-ingress/setup/install-existing/#prerequisites

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME

# Install Azure AD Pod Identity
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm install aad-pod-identity aad-pod-identity/aad-pod-identity -n kube-system

# Check Azure AD Pod identity pods
kubectl get pods -w -n kube-system -l app.kubernetes.io/name=aad-pod-identity

# Create an identity for the AGIC controller
az identity create -g $RESOURCE_GROUP -n $APP_GW_DEV_NAME-identity

# Get client id and id for the identity
APP_GW_DEV_IDENTITY_CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n $APP_GW_DEV_NAME-identity -o tsv --query "clientId")
APP_GW_DEV_IDENTITY_RESOURCE_ID=$(az identity show -g $RESOURCE_GROUP -n $APP_GW_DEV_NAME-identity -o tsv --query "id")

APP_GW_DEV_ID=$(az network application-gateway show -g $RESOURCE_GROUP -n $APP_GW_DEV_NAME --query id -o tsv)

# Assign Contributor role to the identity over the application gateway
az role assignment create \
    --role "Contributor" \
    --assignee $APP_GW_DEV_IDENTITY_CLIENT_ID \
    --scope $APP_GW_DEV_ID

az role assignment create \
    --role "Reader" \
    --assignee $APP_GW_DEV_IDENTITY_CLIENT_ID \
    --scope $RESOURCE_GROUP_ID

# Check role assignments for the user identities
az role assignment list --assignee $APP_GW_DEV_IDENTITY_CLIENT_ID --all -o table

# Add the AGIC Helm repository
helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
helm repo update

### AGIC for dev

# Download the config file
wget https://raw.githubusercontent.com/Azure/application-gateway-kubernetes-ingress/master/docs/examples/sample-helm-config.yaml -O mi/dev-helm-config.yaml

# Create dev namespaces
kubectl create namespace dev-wordpress
kubectl create namespace dev-aspnetapp

# Install Helm chart application-gateway-kubernetes-ingress with the helm-config.yaml configuration from the previous step
helm install agic-dev -f mi/dev-helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure -n kube-system

# Check that ingress is ready
helm list -n kube-system
kubectl get pods -n kube-system -l release=agic-dev

# Deploy a aspnetapp for dev-aspnetapp
kubectl apply -f dev/aspnetsample.yaml
kubectl get pods -n dev-aspnetapp 
kubectl get ingress -n dev-aspnetapp

kubectl logs $(kubectl get pod -n kube-system -l release=agic-dev -o jsonpath='{.items[0].metadata.name}') -n kube-system

# Test the app
APP_GW_DEV_PUBLIC_IP=$(az network public-ip show -g $RESOURCE_GROUP -n $APP_GW_DEV_NAME-public-ip -o tsv --query ipAddress)
curl http://$APP_GW_DEV_PUBLIC_IP
echo http://$APP_GW_DEV_PUBLIC_IP

# Deploy wordpress for dev-wordpress
kubectl apply -f dev/wordpress.yaml -n dev-wordpress
kubectl get pods -n dev-wordpress
kubectl get ingress -n dev-wordpress

# Test the wordpress app
curl http://$APP_GW_DEV_PUBLIC_IP:8080
echo http://$APP_GW_DEV_PUBLIC_IP:8080

######################################
###### Configure AGIC for staging ####
######################################

### Application Gateway for staging ###
APP_GW_STAGING_NAME="app-gw-staging"

# Create public ip
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_STAGING_NAME-public-ip \
--allocation-method Static \
--sku Standard

# Create the app gateway
az network application-gateway create \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_STAGING_NAME \
--location $LOCATION \
--vnet-name $VNET_NAME \
--subnet $APPGW_SUBNET \
--public-ip-address $APP_GW_STAGING_NAME-public-ip \
--sku WAF_v2 \
--capacity 1 

# Create an identity for the AGIC controller
az identity create -g $RESOURCE_GROUP -n $APP_GW_STAGING_NAME-identity

# Get client id and id for the identity
APP_GW_STAGING_IDENTITY_CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n $APP_GW_STAGING_NAME-identity -o tsv --query "clientId")
APP_GW_STAGING_IDENTITY_RESOURCE_ID=$(az identity show -g $RESOURCE_GROUP -n $APP_GW_STAGING_NAME-identity -o tsv --query "id")

APP_GW_STAGING_NAME_ID=$(az network application-gateway show -g $RESOURCE_GROUP -n $APP_GW_STAGING_NAME --query id -o tsv)


# Assign Contributor role to the identity over the application gateway
az role assignment create \
    --role "Contributor" \
    --assignee $APP_GW_STAGING_IDENTITY_CLIENT_ID \
    --scope $APP_GW_STAGING_NAME_ID

az role assignment create \
    --role "Reader" \
    --assignee $APP_GW_STAGING_IDENTITY_CLIENT_ID \
    --scope $RESOURCE_GROUP_ID

# Check role assignments for the user identities
az role assignment list --assignee $APP_GW_STAGING_IDENTITY_CLIENT_ID --all -o table

# Download the config file
wget https://raw.githubusercontent.com/Azure/application-gateway-kubernetes-ingress/master/docs/examples/sample-helm-config.yaml -O mi/staging-helm-config.yaml

# Create dev namespaces
kubectl create namespace staging-whoami
kubectl create namespace staging-drupal

# Install Helm chart application-gateway-kubernetes-ingress with the helm-config.yaml configuration from the previous step
helm install agic-staging -f mi/staging-helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure -n kube-system

# Check that ingress is ready
helm list -n kube-system
kubectl get pods -n kube-system -l release=agic-staging

kubectl logs $(k get pod -l release=agic-staging -o jsonpath='{.items[0].metadata.name}' -n kube-system) -n kube-system

# Deploy whoami for staging-whoami
kubectl apply -f staging/whoami.yaml -n staging-whoami

APP_GW_STAGING_PUBLIC_IP=$(az network public-ip show -g $RESOURCE_GROUP -n $APP_GW_STAGING_NAME-public-ip -o tsv --query ipAddress)
curl http://$APP_GW_STAGING_PUBLIC_IP/whoami
echo http://$APP_GW_STAGING_PUBLIC_IP/whoami

# Deploy drupal for staging-drupal
kubectl apply -f staging/drupal.yaml -n staging-drupal
kubectl get pods -n staging-drupal -w

kubectl logs $(kubectl get pod -l release=agic-staging -o jsonpath='{.items[0].metadata.name}' -n kube-system) -n kube-system

# Test app
echo http://$APP_GW_STAGING_PUBLIC_IP:9090

# Check both agic running in kube-sytem
kubectl get pods -n kube-system -l app=ingress-azure

kubectl get ingressclass -n kube-system