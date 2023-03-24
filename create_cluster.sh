#!/bin/bash
# VAULT-11590


export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
chmod +rx ${DIR}/clean.sh
${DIR}/clean.sh

# create Vault data directory
mkdir -p vault-data
> vault.log

function xecho {
  echo "#### [$@] ####"
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
  address = "127.0.0.1:8200"
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

api_addr = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

EOF

nohup vault server -config=vault.hcl >> vault.log & 
while curl -isk -X GET  http://127.0.0.1:8200/v1/sys/health|tee -a vault.log|head -n1|grep -v 501 ; do
  xecho "Waiting Vault to stabilize..." ; sleep 5
done
xecho "Vault started."

# initialize & unseal vault
vault operator init -key-shares=1 -key-threshold=1 -format=json > init-keys.json 2>&1
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" init-keys.json)
VAULT_ROOT_KEY=$(jq -r ".root_token" init-keys.json)
while curl -isk -X GET  http://127.0.0.1:8200/v1/sys/health|tee -a vault.log|head -n1|grep -v 503 ; do
  xecho "Waiting Vault to reach to seal state..." ; sleep 5
done
vault operator unseal $VAULT_UNSEAL_KEY 1>>vault.log
while curl -isk -X GET  http://127.0.0.1:8200/v1/sys/health|tee -a vault.log|head -n1|grep -v 200 ; do
  xecho "Waiting Vault to reach to unseal and active..." ; sleep 5
done
xecho "Vault is unsealed."

# configure kubernetes auth backend
unset VAULT_TOKEN
vault login -no-print $VAULT_ROOT_KEY 1>>vault.log
vault auth enable kubernetes 1>>vault.log
vault write auth/kubernetes/config \
        kubernetes_host="$(kubectl config view -ojson | jq -r '.clusters[] | select(.name == "kind-v11590") | .cluster.server')" \
        kubernetes_ca_cert="$(kubectl get cm kube-root-ca.crt -ojson | jq -r '.data["ca.crt"]')" \
        token_reviewer_jwt=$VAULT_REVIEWER_JWT 1>>vault.log

# create kubernetes "default" auth role
vault write auth/kubernetes/role/default \
        bound_service_account_names=default \
        bound_service_account_namespaces=default \
        policies=default 1>>vault.log

# generate test serviceaccount token
xecho "Generate a Kubernetes test serviceaccount token"
DEFAULT_JWT=$(kubectl create token default)
sleep 2
# attempt login => success
xecho "Attempt login"
vault write -format=json auth/kubernetes/login role=default jwt=$DEFAULT_JWT |tee -a vault.log |jq -r ".auth.client_token" > kube.token
unset VAULT_TOKEN ;
vault login $(cat kube.token)
read x
xecho "Stopping Vault"
# stop vault
pvault=$(pgrep -o vault) && kill $pvault

xecho "Starting Vault"
nohup vault server -config=vault.hcl 1 >> vault.log &
while curl -isk -X GET http://127.0.0.1:8200/v1/sys/health|tee -a vault.log|head -n1|grep -v '503' ; do
  xecho "Waiting Vault to reach to seal state..." ; sleep 5
done
xecho "Vault is sealed."

vault operator unseal $VAULT_UNSEAL_KEY 1>>vault.log
# attempt login => failure (x509: “kube-apiserver” certificate is not trusted)
while curl -sk -X GET  http://127.0.0.1:8200/v1/sys/health|tee -a vault.log|jq -r '.sealed'|grep 'true' ; do
  xecho "Waiting Vault to reach to unseal and active state..." ; sleep 5
done
xecho "Vault is unsealed and active."

vault login -no-print $VAULT_ROOT_KEY 1>>vault.log

xecho "Attempt a second login"
xecho "Generate a Kubernetes test serviceaccount token"
DEFAULT_JWT=$(kubectl create token default)
vault write -format=json auth/kubernetes/login role=default jwt=$DEFAULT_JWT |tee -a vault.log |jq -r '.auth.client_token' >kube.token
vault login $(cat kube.token)

curl -ivsk -X GET  http://127.0.0.1:8200/v1/sys/health
vault status

xecho "Delete kind cluster?(y/n)[Default n]" && read x 
[ "Z${x}" == "Zy" ] && kind delete cluster --name v11590 || xecho "Kind cluster v11590 was left running..."

chmod +rx ${DIR}/clean.sh
${DIR}/clean.sh

# Checking response code 
# while : ; do
#  curl -isk -X GET  http://127.0.0.1:8200/v1/sys/health|head -n1|cut -d ' ' -f 2
#  sleep 1
# done
