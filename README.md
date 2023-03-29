# vault-on-kind-localhost
[![license](http://img.shields.io/badge/license-apache_2.0-red.svg?style=flat)](https://github.com/florintp-onboarding/vault-on-kind-localhost/blob/main/LICENSE)

# The scope of this repository is to deploy a Vault cluster with RAFT storage backend into an KIND local Kubernetes cluster.

The repo is takinig into consideration the HTTP response codes as per [Vault Health API](https://developer.hashicorp.com/vault/api-docs/system/health)

----

## Requirements
 - A Vault Server [https://www.vaultproject.io]
 - KIND tool for running local Kubernetes clusters [Install notes](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
 - Kubernetes CLI (https://kubernetes.io/docs/tasks/tools/install-kubectl/)
 - Docker Desktop [Download Docker](https://www.docker.com/products/docker-desktop/)
 - JQ package [JQ Download](https://stedolan.github.io/jq/download/)

----
## Steps to deploy a KIND cluster and install a Vault server
1. First, install the latest KIND Kubernetes
 - Kubectl CLI [`kubectl version`]
 - KIND tool [`kind version`]
 - Docker [`docker version`]
 - JQ tool [`jq --version`]
 - Vault Server binary [`vault version`]

2. Set the location of your working directory and clone this repo
````shell
gh repo clone florintp-onboarding/vault-on-kind-localhost
````

3. Execute the creation script
```shell
chmod +rx create_cluster.sh
bash create_cluster.sh
```

4.  The ouput might look like:
```shell
This script creates a KIND Kubernetes cluster, a Vault with raft storage and test the Kubernetes AUTH.
View the README.md for complete guide.

Usage: create_cluster.sh [clean]
No kind clusters found.
Creating cluster "v11590" ...
 ✓ Ensuring node image (kindest/node:v1.25.3) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-v11590"
You can now use your cluster with:

kubectl cluster-info --context kind-v11590

Have a nice day! 👋
serviceaccount/vault created
clusterrolebinding.rbac.authorization.k8s.io/system:auth-delegator:vault created

#### [Vault started.] ####
HTTP/1.1 429 Too Many Requests

#### [Waiting Vault to reach to unseal and active...] ####

#### [Vault is unsealed.] ####

#### [Generate a Kubernetes test serviceaccount token] ####

#### [Attempt login with the JWT] ####
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
again. Future Vault requests will automatically use this token.

Key                                       Value
---                                       -----
token                                     hvs.CAESIANZJCK5-jwE2TjTblZOGqdfuHtjvFSEWI2ZsOC5xkWHGh4KHGh2cy53R2pWTGIwS2NhTWJIcDNIWktjOU02WUo
token_accessor                            pfTee12RYVf75LF0BTk6eOdb
token_duration                            768h
token_renewable                           true
token_policies                            ["default"]
identity_policies                         []
policies                                  ["default"]
token_meta_service_account_uid            70811a92-e2aa-428c-a9bd-bd58a86a0935
token_meta_role                           default
token_meta_service_account_name           default
token_meta_service_account_namespace      default
token_meta_service_account_secret_name    n/a

#### [Keep kind cluster?(y)[Default n]] ####
```

5. Cleanup the infrastructure and local files
```shell
kind delete cluster --name=v11590
bash clean.sh
```

