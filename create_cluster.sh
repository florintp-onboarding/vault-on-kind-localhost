#!/bin/bash
# VAULT-11590 and experiment events.alhpa1

# ENV BLOCK
export VAULT_IP="127.0.0.1"
export VAULT_ADDR="http://${VAULT_IP}:8200"
export VAULT_REVIEWER_JWT=""
export script_name="$(basename "$0")"
export os_name="$(uname -s | awk '{print tolower($0)}')"

if [ "$os_name" != "darwin" ] && [ "$os_name" != "linux" ]; then
  >&2 echo "Sorry, this script supports only Linux or macOS operating systems."
  exit 1
fi

if netstat -an|grep LISTEN|grep ':8200' ||
   netstat -an|grep LISTEN|grep '127.0.0.1.8200' ; then
  >&2 echo "Sorry, there is a dameon already listening on 8200."
  exit 2
fi

export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
chmod +rx ${DIR}/clean.sh
${DIR}/clean.sh

# create Vault data directory
mkdir -p vault-data
> vault.log

#FUNCTION BLOCK
function xecho {
  printf "\n%s\n" "#### [$@] ####"
}

function xvault {
    (export VAULT_ADDR=http://127.0.0.1:8200 && vault "$@")
}

#create k8s cluster via kind
function createkind {
  xecho "Creating KIND Cluster with name v11590"
  kind -q get clusters |grep v11590
  if [ $? -eq 0 ] ; then
    xecho "Kind cluster already present!"
    kind -q delete cluster --name=v11590 
    kind -q get clusters
  fi
  kind -q create cluster --name v11590 
  
  # create vault serviceaccount & binding
  kubectl create sa vault
  kubectl create clusterrolebinding \
          system:auth-delegator:vault \
          --clusterrole=system:auth-delegator \
          --serviceaccount=default:vault
  
  # create vault reviewer token
  export VAULT_REVIEWER_JWT=$(kubectl create token vault)
}

function createvault {
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
  address = "${VAULT_IP}:8200"
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

api_addr = "http://${VAULT_IP}:8200"
cluster_addr = "http://127.0.0.1:8201"

EOF
  nohup vault server -config=vault.hcl -experiment events.alpha1 >> vault.log & 
  while curl -isk -X GET  http://${VAULT_IP}:8200/v1/sys/health|tee -a vault.log|head -n1|grep -v 501 ; do
    xecho "Waiting Vault to stabilize..." ; sleep 5
  done
  xecho "Vault started."
  sleep 2 
  # initialize & unseal vault
  xvault operator init -key-shares=1 -key-threshold=1 -format=json > init-keys.json 2>&1
  VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" init-keys.json)
  VAULT_ROOT_KEY=$(jq -r ".root_token" init-keys.json)
  while curl -isk -X GET  http://${VAULT_IP}:8200/v1/sys/health|tee -a vault.log|head -n1|grep -v 503 ; do
    xecho "Waiting Vault to reach to seal state..." ; sleep 5
  done
  
  xvault operator unseal $VAULT_UNSEAL_KEY 1>>vault.log
  while curl -isk -X GET  http://${VAULT_IP}:8200/v1/sys/health|tee -a vault.log|head -n1|grep -v 200 ; do
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
}

function testauth {
  # generate test serviceaccount token
  xecho "Generate a Kubernetes test serviceaccount token"
  export DEFAULT_JWT=$(kubectl create token default)
  sleep 2

  xecho "Attempt login with the JWT"
  unset VAULT_TOKEN ; rm -f ~/.vault-token
  xvault write -format=json auth/kubernetes/login role=default jwt=$DEFAULT_JWT|jq -r ".auth.client_token" > kube.token
  xvault login $(cat kube.token) 

 ## xecho "Attempt a second login with a new Kubernetes token"
 ## xecho "Generate a Kubernetes test serviceaccount token"
 ## DEFAULT_JWT=$(kubectl create token default)
 ## unset VAULT_TOKEN ; rm -f ~/.vault-token
 ## xvault write -format=json auth/kubernetes/login role=default jwt=$DEFAULT_JWT |jq -r '.auth.client_token' >kube.token
 ## xvault login $(cat kube.token) 
  
}

# MAIN script
#
case "$1" in
  clean)
    shift ;
     kind delete cluster --name=v11590
     kind get clusters
     chmod +rx ${DIR}/clean.sh
     ${DIR}/clean.sh
     exit
     ;;
  *)
    printf "\n%s" \
      "This script creates a KIND Kubernetes cluster, a Vault with raft storage and test the Kubernetes AUTH." \
      "View the README.md for complete guide." \
      "" \
      "Usage: $script_name [clean]" \
      "";
    createkind
    createvault
    testauth
    ;;
esac


xecho "Keep kind cluster?(y)[Default n]" && read x 
[ "Z${x}" == "Zy" ] ||  kind delete cluster --name v11590 && xecho "Kind cluster v11590 was left running..."

chmod +rx ${DIR}/clean.sh
${DIR}/clean.sh

