#Prior to running setup, ensure docker is running first. 
Write-Host "Pre-Setup checks" -ForegroundColor DarkYellow
Write-Host "Checking Docker..." -ForegroundColor Blue
$dockerInfo = docker info 2>$null

#Step 1: Login and check docker
az login
Write-Host "Checking Azure Login status..." -ForegroundColor Yellow
$profile = az account show 2>$null
if (-not $profile) {
    Write-Host "ERROR: Not logged in to Azure. Please run 'az login' first." -ForegroundColor Red
    exit 1
}
Write-Host "Logged in successfully." -ForegroundColor Green

if (-not $dockerInfo) {
    Write-Host "ERROR: Docker is not running or not installed." -ForegroundColor Red
    Write-Host "Please do the following:" -ForegroundColor Yellow
    Write-Host "1. Open Docker Desktop." -ForegroundColor White
    Write-Host "2. Ensure it is in 'Linux Containers' mode (bottom right whale icon)." -ForegroundColor White
    Write-Host "3. Wait for the status to say 'Engine running'." -ForegroundColor White
    Write-Host "4. Re-run this script." -ForegroundColor White
    exit 1
}

##Module 1: The Foundation & ACR Structure
Write-Host "Module 1: The Foundation & ACR Structure" -ForegroundColor DarkYellow
#Define the resource names
$RG = "rgsecureaigateway"
$LOC = "australiaeast"
$ENV = "envsecureaigateway"
$ACR = "acrsecureaigateway"
$InternalCA = "secureaigatewayinternal"
$PublicCA = "secureaigatewaypublic"

Write-Host "Create the Logical Boundaries" -ForegroundColor Blue


#Step 2: Create Container Apps Environment (Shared networking/logging)
Write-Host "Create Container Apps Environments" -ForegroundColor Blue
az group create --name $RG --location $LOC

#Step 3: Create ACR (The Registry Level)
#SKU Basic is sufficient for storage; we avoid "Tasks" to save money
Write-Host "Create Azure Container Registry" -ForegroundColor Cyan
az acr create --resource-group $RG --name $ACR --sku Basic --admin-enabled false
Write-Host "Created the Logical Boundaries!" -ForegroundColor Green

Write-Host "Build & Tag (The Repository/Artifact Level)" -ForegroundColor Blue
#Step 4: Login to ACR
Write-Host "Logging into Azure Container Registry" -ForegroundColor Cyan
az acr login --name $ACR

#Step 5: Build locally and tag with a UNIQUE Git-like SHA (Best Practice)
Write-Host "Create an artifact in the repository" -ForegroundColor Cyan
docker build -t $ACR.azurecr.io/ai-inference:$(git rev-parse --short HEAD) .

#Step 6: Push to the registry
Write-Host "Push to the registry" -ForegroundColor Cyan
docker push $ACR.azurecr.io/ai-inference:$(git rev-parse --short HEAD)

##Module 2: Security & Authentication
Write-Host "Module 2: Security & Authentication" -ForegroundColor DarkYellow
#Step 1: Create the System-Assigned Managed Identity on the Container App
Write-Host "Create the System-Assigned Managed Identity on the Container App" -ForegroundColor Blue

#Create the App
az containerapp create `
 --name $InternalCA `
 --resource-group $RG `
 --environment $ENV `
 --image $ACR.azurecr.io/ai-inference:latest `
 --target-port 8080 `
 --ingress internal `
 --system-assigned-identity `
 --registry-server "$ACR.azurecr.io" 

#Step 2: Grant the Managed Identity permission to pull images (The Least Privilege Step)
Write-Host "Grant the Managed Identity permission to pull images (The Least Privilege Step)" -ForegroundColor Cyan
#You need the Identity Principal ID because it is the unique, immutable identifier that Azure uses to
#distinguish your Container App's managed identity from every other identity in your Azure environment.
Write-Host "Get the Identity Principle ID" -ForegroundColor Cyan
$IDENTITY_PRINCIPLE_ID = $(az containerapp show --name $InternalCA --resource-group $RG --query "identity.principalId" -o tsv)
#The -o tsv flag stands for Output format: Tab-Separated Values.
Write-Host "Assign the AcrPull role" -ForegroundColor Cyan
az role assiginment create --assignee $IDENTITY_PRINCIPLE_ID --role "AcrPull" --scope $(az acr show --name $ACR --query "id" -o tsv)
#Verification: Check the Logs for the app. If it says "ImagePullBackOff", the identity didn't have permission. 
#If it starts, the Managed Identity worked.

Write-Host "Manage Secrets (Environment Variables)" -ForegroundColor Blue
#Step 1: Set a secret in the container app.
Write-Host "Set a secret in the container app" -ForegroundColor Cyan
az containerapp secret set --name $InternalCA --resource-group $RG --secrets "AI_API_KEY=secret12345"

#Step 2: Map the secret to an environment variable in the container 
Write-Host "Map the secret to an Environment Variable in the container" -ForegroundColor White
az containerapp update --name $InternalCA --resource-group $RG --set-env-vars "API_KEY=secretref:AI_API_KEY"

##Module 3: Networking & Revisions
#Concepts Applied: External vs. Internal Ingress, Revisions, Traffic Splitting.
Write-Host "Module 3: Networking & Revisions" -ForegroundColor DarkYellow
#Step 1: Deploy the Public API
#Now we deploy a second app that is External and talks to the internal one.
Write-Host "Deploy the Public API (External Ingress)" -ForegroundColor Blue
# Using the same image for simplicity, but in reality, this would be a different service
az containerapp create `
--name $PublicCA `
--resource-group `
$RG --environment `
$ENV --image $ACR.azurecr.io/ai-inference:latest `
--target-port 8080 `
--ingress external `
--system-assigned-identity `
--registry-server $ACR.azurecr.io

#Check the public URL.
Write-Host "Check the Public URL" -ForegroundColor Cyan
az containerapp show --name $PublicCA --resource-group $RG --query "properties.configuration.ingress.fqdn"

Write-Host "The Revision Lifecycle (Zero Downtime)" -ForegroundColor Blue
Write-Host "Trigger a New Revision" -ForegroundColor Cyan
#Trigger a New Revision: Change an environment variable. This creates a new Revision.
az containerapp update --name $InternalCA --resource-group $RG --set-env-vars "VERSION=v2"

Write-Host "Inspect Revision" -ForegroundColor Cyan
az containerapp revision list --name $InternalCA --resource-group $RG 

Write-Host "Rollback (If needed)" -ForegroundColor Cyan
az containerapp update --name $InternalCA --resource-group $RG --set revisionName="VERSION=v1"

##Module 4: Observability & Troubleshooting
#Concepts Applied: Logs (stdout/stderr), KQL queries, Health Checks.
Write-Host "Module 4: Observability & Troubleshooting" -ForegroundColor DarkYellow
Write-Host "Query Logs (The Data-Dependent Failure)" -ForegroundColor Blue
az containerapp logs show --name $InternalCA --resource-group $RG --follow --tail 20

Write-Host "Simulate a Failure & Debug" -ForegroundColor Blue
Write-Host "Force a crash" -ForegroundColor White
az containerapp update --name ai-internal --resource-group $RG --set-env-vars "PORT=9999"

Write-Host "Check Replica Status" -ForegroundColor Cyan
az containerapp replica list --name ai-internal --resource-group $RG

Write-Host "Check System Logs" -ForegroundColor Cyan
az containerapp logs show --name ai-internal --resource-group $RG --type system

##Module 5: Checklist and cleanup
Write-Host "Display results" -ForegroundColor Blue
az acr repository list --name $ACR --output table
az acr repository show-tags --name $ACR --repository ai-inference --output table

Write-Host "Delete the group to avoid charges" -ForegroundColor Blue
az group delete --name $RG --yes --no-wait