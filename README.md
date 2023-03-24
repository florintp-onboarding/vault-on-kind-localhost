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

4. Export the VAULT_ADDR, VAULT_TOKEN, login to Vault and check the status of Vault cluster
```shell
unset VAULT_TOKEN
export VAULT_ADDR="http://127.0.0.1:8200"
vault status
export VAULT_TOKEN=$(jq -r ".root_token" init-keys.json)
vault login $VAULT_TOKEN
vault auth list
vault operator raft list-peers
```

5. Cleanup the infrastructure and local files
```shell
kind delete cluster --name=v11590
bash clean.sh
```

