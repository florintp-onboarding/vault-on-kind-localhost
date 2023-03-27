#!/bin/bash
# VAULT-11590 and experiment events.alhpa1

# ENV BLOCK
export VAULT_ADDR="127.0.0.1:8200"
export script_name="$(basename "$0")"
export os_name="$(uname -s | awk '{print tolower($0)}')"

if [ "$os_name" != "darwin" ] && [ "$os_name" != "linux" ]; then
  >&2 echo "Sorry, this script supports only Linux or macOS operating systems."
  exit 1
fi

export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
chmod +rx ${DIR}/clean.sh
${DIR}/clean.sh

# create Vault data directory
mkdir -p vault-data
> vault.log

#FUNCTION BLOCK
function xecho {
  echo "#### [$@] ####"
}

function xvault {
    (export VAULT_ADDR=http://${VAULT_ADDR?} && vault "$@")
}

#create k8s cluster via kind
kind get clusters |grep v11590
if [ $? -eq 0 ] ; then
  xecho "Kind cluster already present!"
  if [ $# -ge 1 ] ; then
     kind delete cluster --name=v11590 
     kind get clusters
  else
    xecho "Use ./$0 clean! Exit 1..."
    exit 1
  fi
fi
kind create cluster --name v11590 

# create vault serviceaccount & binding
kubectl create sa vault
kubectl create clusterrolebinding \
        system:auth-delegator:vault \
        --clusterrole=system:auth-delegator \
        --serviceaccount=default:vault

# create vault reviewer token
VAULT_REVIEWER_JWT=$(kubectl create token vault)


cat <<- EOF > vault.hcl

ui = true
disable_mlock = true
log_level = "trace"
raw_storage_endpoint = true
enable_response_header_hostname = true
enable_response_header_raft_node_id = true

# listener
listener "tcp" {
  tls_disable = true
  address = "${VAULT_ADDR}"
  cluster_address = "127.0.0.1:8201"
  telemetry {
    unauthenticated_metrics_access = true
  }
}

# storage backend
storage "raft" {
  path = "./vault-data"
  node_id = "raft_node_1"
}

api_addr = "http://${VAULT_ADDR}"
cluster_addr = "http://127.0.0.1:8201"

EOF

nohup vault server -config=vault.hcl -experiment events.alpha1 >> vault.log & 
while curl -isk -X GET  http://${VAULT_ADDR?}/v1/sys/health|tee -a vault.log|head -n1|grep -v 501 ; do
  xecho "Waiting Vault to stabilize..." ; sleep 5
done
xecho "Vault started."

# initialize & unseal vault
xvault operator init -key-shares=1 -key-threshold=1 -format=json > init-keys.json 2>&1
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" init-keys.json)
VAULT_ROOT_KEY=$(jq -r ".root_token" init-keys.json)

while curl -isk -X GET  http://${VAULT_ADDR?}/v1/sys/health|tee -a vault.log|head -n1|grep -v 503 ; do
  xecho "Waiting Vault to reach to seal state..." ; sleep 5
done

xvault operator unseal $VAULT_UNSEAL_KEY 1>>vault.log
while curl -isk -X GET  http://${VAULT_ADDR?}/v1/sys/health|tee -a vault.log|head -n1|grep -v 200 ; do
  xecho "Waiting Vault to reach to unseal and active..." ; sleep 5
done
xecho "Vault is unsealed."

# configure kubernetes auth backend
unset VAULT_TOKEN
xvault login -no-print $VAULT_ROOT_KEY 1>>vault.log
xvault auth enable kubernetes 1>>vault.log
xvault write auth/kubernetes/config \
        kubernetes_host="$(kubectl config view -ojson | jq -r '.clusters[] | select(.name == "kind-v11590") | .cluster.server')" \
        kubernetes_ca_cert="$(kubectl get cm kube-root-ca.crt -ojson | jq -r '.data["ca.crt"]')" \
        token_reviewer_jwt=$VAULT_REVIEWER_JWT 1>>vault.log

# create kubernetes "default" auth role
xvault write auth/kubernetes/role/default \
        bound_service_account_names=default \
        bound_service_account_namespaces=default \
        policies=default 1>>vault.log

# generate test serviceaccount token
xecho "Generate a Kubernetes test serviceaccount token"
DEFAULT_JWT=$(kubectl create token default)
sleep 2

# attempt login => success
xecho "Attempt login"
xvault write -format=json auth/kubernetes/login role=default jwt=$DEFAULT_JWT |tee -a vault.log |jq -r ".auth.client_token" > kube.token
unset VAULT_TOKEN ;
xvault login $(cat kube.token)

xecho "AUTH via Kubernetes Vault auth performed. Moving to events."
xecho "Press ENTER to continue>"
read x

xecho "Stopping Vault"
# stop vault
pvault=$(pgrep -o vault) && kill $pvault

xecho "Starting Vault"
nohup vault server -config=vault.hcl -experiment events.alpha1 1>> vault.log &
while curl -isk -X GET http://${VAULT_ADDR?}/v1/sys/health|tee -a vault.log|head -n1|grep -v '503' ; do
  xecho "Waiting Vault to reach to seal state..." ; sleep 5
done
xecho "Vault is sealed."

xvault operator unseal $VAULT_UNSEAL_KEY 1>>vault.log
# attempt login => failure (x509: “kube-apiserver” certificate is not trusted)
while curl -sk -X GET  http://${VAULT_ADDR?}/v1/sys/health|tee -a vault.log|jq -r '.sealed'|grep 'true' ; do
  xecho "Waiting Vault to reach to unseal and active state..." ; sleep 5
done
xecho "Vault is unsealed and active."

xvault login -no-print $VAULT_ROOT_KEY 1>>vault.log

xecho "Attempt a second login"
xecho "Generate a Kubernetes test serviceaccount token"
DEFAULT_JWT=$(kubectl create token default)
xvault write -format=json auth/kubernetes/login role=default jwt=$DEFAULT_JWT |tee -a vault.log |jq -r '.auth.client_token' >kube.token
xvault login $(cat kube.token)

curl -ivsk -X GET  http://${VAULT_ADDR?}/v1/sys/health
xvault status

# enable a KV-V2 secrets mount
unset VAULT_TOKEN
export VAULT_TOKEN=$(jq -r ".root_token" init-keys.json)
xvault login $VAULT_TOKEN 1>> vault.log

xecho "Enable a KV-V2 secrets mount"
xvault secrets enable -path=testevent kv-v2

xecho "Open a new terminal and observe the events while writting a secret into the mount secrets testevent"
xecho "For example:
export VAULT_ADDR=http://${VAULT_ADDR} ; unset VAULT_TOKEN
export VAULT_TOKEN='$(jq -r ".root_token" init-keys.json)'
vault login '$VAULT_TOKEN'
vault secrets list
vault events subscribe kv-v2/data-write"

xecho "Press ENTER to write a KV-V2 secret"
read x

xvault kv put testevent/app/secret1 user=Roger pass=NoPass
read x

xvault kv get testevent/app/secret1 

read x
xvault kv put testevent/app/secret1 user=Michael pass=NoTSet

read x
xvault kv get testevent/app/secret1 

xecho ""

xecho "Delete kind cluster?(y/n)[Default n]" && read x 
[ "Z${x}" == "Zy" ] && kind delete cluster --name v11590 || xecho "Kind cluster v11590 was left running..."

chmod +rx ${DIR}/clean.sh
${DIR}/clean.sh

# Checking response code 
# while : ; do
#  curl -isk -X GET  http://127.0.0.1:8200/v1/sys/health|head -n1|cut -d ' ' -f 2
#  sleep 1
# done
