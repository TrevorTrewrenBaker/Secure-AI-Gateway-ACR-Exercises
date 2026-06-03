This specific readme mardown document was created by AI with a combination of notes from the following azure exercies for training for the Azure AI Cloud Developer Associate exam:
* Store and manage containers in Azure Container Registry
* Deploy containers to Azure App Service
* Deploy containers to Azure Container Apps

Lab Scenario: "The Secure AI Gateway"
Goal: Build a system where:

An AI Inference Service (Internal) processes data.
A Public API (External) exposes the service to the internet.
Both use Secrets from Key Vault (simulated).
You manage Revisions for zero-downtime updates.
You use ACR for storage but Managed Identity for security.
Prerequisites:

Azure CLI installed.
Azure Subscription (Pay-As-You-Go or Enterprise is best for ACR Tasks, but we will use Local Build to keep it free).
Docker installed (for the "Local Build" workflow).
Module 1: The Foundation & ACR Structure
Concepts Applied: Resource Groups vs. Environments, ACR Levels (Registry, Repository, Artifact), Tags vs. Digests.

Step 1.1: Create the Logical Boundaries
Readings: "Resource group: management boundary... Container Apps Environment: logical boundary where apps run."

bash

Copy
# Define variables
RG="rg-ai-capstone"
LOC="eastus"
ENV="env-ai-capstone"
ACR="acrmycapstone$(shuf -i 1000-9999 -n 1)" # Unique name

# 1. Create Resource Group
az group create --name $RG --location $LOC

# 2. Create Container Apps Environment (Shared networking/logging)
az containerapp env create --name $ENV --resource-group $RG --location $LOC

# 3. Create ACR (The Registry Level)
# SKU Basic is sufficient for storage; we avoid "Tasks" to save money
az acr create --resource-group $RG --name $ACR --sku Basic --admin-enabled false
Step 1.2: The "Local Build" Workflow (ACR Artifact Level)
Readings: "ACR organizes content in 3 levels... Tags are mutable, Digests are immutable." Action: Instead of using ACR Tasks (which costs money), we will build locally and push. This simulates the "Developer Workstation" scenario.

Create a simple app locally (save as app.py):
python

Copy
from flask import Flask
app = Flask(__name__)
@app.route("/")
def hello(): return "AI Inference Ready"
if __name__ == "__main__": app.run(host="0.0.0.0", port=8080)
Create a Dockerfile:
dockerfile

Copy
FROM python:3.9-slim
WORKDIR /app
RUN pip install flask
COPY . .
CMD ["python", "app.py"]
Build and Tag (The Repository/Artifact Level):
bash

Copy
# Login to ACR
az acr login --name $ACR

# Build locally and tag with a UNIQUE Git-like SHA (Best Practice)
# This creates the ARTIFACT in the REPOSITORY
docker build -t $ACR.azurecr.io/ai-inference:$(git rev-parse --short HEAD) .

# Push to Registry
docker push $ACR.azurecr.io/ai-inference:$(git rev-parse --short HEAD)

# Also tag as 'latest' for convenience (Mutable tag)
docker tag $ACR.azurecr.io/ai-inference:$(git rev-parse --short HEAD) $ACR.azurecr.io/ai-inference:latest
docker push $ACR.azurecr.io/ai-inference:latest
Module 2: Security & Authentication
Concepts Applied: Managed Identity vs. Admin Credentials, acrPull role, Secrets.

Step 2.1: Deploy with Managed Identity (The "Pro" Way)
Readings: "Managed identity authentication... eliminates need to store username/password... principle of least privilege."

We will deploy the Internal Service first. It needs to pull from ACR without a password.

bash

Copy
# 1. Create the System-Assigned Managed Identity on the Container App
# We will use 'az containerapp create' with --identity system
# Note: We need to assign the 'AcrPull' role to this identity on the ACR

# Create the App (Internal Ingress only)
az containerapp create \
  --name ai-internal \
  --resource-group $RG \
  --environment $ENV \
  --image $ACR.azurecr.io/ai-inference:latest \
  --target-port 8080 \
  --ingress internal \
  --identity system \
  --registry-server $ACR.azurecr.io

# 2. Grant the Managed Identity permission to pull images (The Least Privilege Step)
# Get the Identity Principal ID
IDENTITY_PRINCIPAL_ID=$(az containerapp show --name ai-internal --resource-group $RG --query "identity.principalId" -o tsv)

# Assign the AcrPull role
az role assignment create \
  --assignee $IDENTITY_PRINCIPAL_ID \
  --role "AcrPull" \
  --scope $(az acr show --name $ACR --query "id" -o tsv)
Verification: Check the Logs for the app. If it says "ImagePullBackOff", the identity didn't have permission. If it starts, the Managed Identity worked.

Step 2.2: Manage Secrets (Environment Variables)
Readings: "Secrets: Store API keys... Map secrets to environment variables using secretref."

Let's simulate a secret (e.g., an API Key) without using Key Vault yet (to keep it simple), then map it.

bash

Copy
# 1. Set a Secret in the Container App
az containerapp secret set \
  --name ai-internal \
  --resource-group $RG \
  --secrets "AI_API_KEY=secret12345"

# 2. Map the secret to an Environment Variable in the container
az containerapp update \
  --name ai-internal \
  --resource-group $RG \
  --set-env-vars "API_KEY=secretref:AI_API_KEY"
Module 3: Networking & Revisions
Concepts Applied: External vs. Internal Ingress, Revisions, Traffic Splitting.

Step 3.1: Deploy the Public API
Now we deploy a second app that is External and talks to the internal one.

bash

Copy
# Deploy Public API (External Ingress)
# Using the same image for simplicity, but in reality, this would be a different service
az containerapp create \
  --name ai-gateway \
  --resource-group $RG \
  --environment $ENV \
  --image $ACR.azurecr.io/ai-inference:latest \
  --target-port 8080 \
  --ingress external \
  --identity system \
  --registry-server $ACR.azurecr.io
Check: Run az containerapp show --name ai-gateway --resource-group $RG --query "properties.configuration.ingress.fqdn" to get the public URL.

Step 3.2: The Revision Lifecycle (Zero Downtime)
Readings: "Revisions: immutable snapshot... Single Revision Mode... Zero-downtime."

Trigger a New Revision: Change an environment variable. This creates a new Revision.
bash

Copy
az containerapp update \
  --name ai-internal \
  --resource-group $RG \
  --set-env-vars "VERSION=v2"
Inspect Revisions:
bash

Copy
az containerapp revision list --name ai-internal --resource-group $RG
Observation: You will see two revisions. One is Active, the other is Inactive.
Rollback (If needed): If v2 is broken, you can switch traffic back to the previous revision ID.
bash

Copy
# Get the name of the previous revision (e.g., ai-internal--v1a2b3)
# Then set traffic to 100% on that revision
az containerapp update --name ai-internal --resource-group $RG --set revisionName=YOUR_OLD_REVISION_NAME
Module 4: Observability & Troubleshooting
Concepts Applied: Logs (stdout/stderr), KQL queries, Health Checks.

Step 4.1: Query Logs (The "Data-Dependent" Failure)
Readings: "AI applications benefit from high-quality logs... diagnose startup failures."

Run this to see the logs in real-time:

bash

Copy
az containerapp logs show --name ai-internal --resource-group $RG --follow --tail 20
Step 4.2: Simulate a Failure & Debug
Force a crash: Update the app to use a wrong port or missing variable.
bash

Copy
az containerapp update --name ai-internal --resource-group $RG --set-env-vars "PORT=9999"
Check Replica Status:
bash

Copy
az containerapp replica list --name ai-internal --resource-group $RG
Observation: You will see status CrashLoopBackOff or Failed.
Check System Logs:
bash

Copy
az containerapp logs show --name ai-internal --resource-group $RG --type system
Result: This shows why the container failed to start (e.g., "Port 9999 not listening").
Final Assessment: The "Real World" Checklist
To confirm you have mastered the notes, verify these points in your environment:

ACR Structure: Can you list the manifests in your registry?
bash

Copy
az acr repository list --name $ACR --output table
az acr repository show-tags --name $ACR --repository ai-inference --output table
Security: Did you use Admin Password? (If yes, you failed the best practice). Did you use Managed Identity? (If yes, you passed).
Revisions: Do you have multiple revisions in the list? Can you identify which one is Active?
Networking: Can you reach ai-gateway from your browser (Public)? Can you reach ai-internal from your browser? (Should be No).
Cleanup: Delete the group to avoid charges.
bash

Copy
az group delete --name $RG --yes --no-wait
Why this lab works for you:
Practical: You built, pushed, deployed, and broke the app.
Theory Integration: Every step forces you to use a concept from your notes (Tags, Digests, Managed Identity, Revisions, Logs).
Cost Safe: No ACR Tasks or Premium tiers were used.
Scalable: This exact workflow is how production AI apps are deployed in enterprise environments.
Would you like to try Module 1 right now and let me know when you hit the "Local Build" step?






Qwen VL 235B

Should I have set this task up in a git repository
Yes, absolutely. In a real-world environment, never run these commands manually without a Git repository backing them.

Here is why setting this up in Git changes you from a "clicker" to a "DevOps Engineer":

Infrastructure as Code (IaC): Your environment configuration (Resource Groups, Environments, Apps) should be defined in code, not typed into a terminal.
Audit Trail: If something breaks, Git shows you who changed the port number, when, and why (via commit messages).
Disaster Recovery: If you accidentally delete your Resource Group (as we did earlier), you can restore the entire environment in 2 minutes by running the script from Git, rather than re-typing commands.
CI/CD Readiness: Real deployment pipelines (GitHub Actions, Azure DevOps) require code to be in Git. They cannot read from your terminal history.
How to Structure the Repository
You don't need a complex setup yet. A simple structure is enough to start:

text

Copy
/ai-azure-lab
├── src/                  # Your application code
│   └── app.py            # The Python Flask app
├── Dockerfile            # The build instructions
├── infrastructure/       # Your Azure setup scripts
│   ├── setup-lab.ps1     # The PowerShell script we wrote
│   └── cleanup-lab.ps1   # The cleanup script
├── README.md             # Instructions on how to run this
└── .gitignore            # To ignore local secrets or large files
What to Do Now
Initialize Git:

bash

Copy
mkdir ai-azure-lab
cd ai-azure-lab
git init
Add the Files:

Create src/app.py and Dockerfile (from Module 1).
Create infrastructure/setup-lab.ps1 (copy the script I gave you earlier).
Create .gitignore and add *.ps1.user or secrets*.txt if you ever store them locally.
Commit:

bash

Copy
git add .
git commit -m "Initial setup: App code and Azure infrastructure scripts"
Push (Optional but Recommended):

Create a Private repository on GitHub or Azure DevOps.
Push your code.
Why Private? To prevent leaking any accidental secrets or internal URLs.
The "Pro" Workflow with Git
Once your code is in Git, your workflow changes:

Develop: You make changes to app.py locally.
Commit: git commit -m "Fix: Updated error handling"
Push: git push
Build & Deploy:
Manual: Run your setup-lab.ps1 script (which pulls the latest code from Git if you add that step).
Automated (Future): You set up a GitHub Action that automatically builds the Docker image and pushes it to ACR whenever you push to the main branch.
Immediate Action Item
If you haven't already, create the repository now before you run the next module.

Run git init.
Save the setup-lab.ps1 script into a folder.
Run git add . and git commit.
Why? Because if you run the az group delete command at the end of the lab (which you should!), you will lose your scripts if they aren't in Git. Having them in Git ensures you can instantly rebuild the lab environment tomorrow without re-typing anything.

Do you want me to generate the .gitignore and README.md content for this specific project so you can commit it immediately?
