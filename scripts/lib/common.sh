#!/usr/bin/env bash
# Configuração compartilhada: convenção de nomes, tags padrão, estado e helpers.

# ---------------------------------------------------------------- identidade
# Produto fictício do laboratório: "Shield", plataforma antifraude de pagamentos.
# Convenção de nome: <tipo>-<ambiente>-<produto>-<escopo>
PRODUCT="shield"
ENVIRONMENT="prd"
REGION_SHORT="us"

# ------------------------------------------------------------------ endpoint
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-AKIALOCALSHIELD00000}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-shield-local-only-not-a-real-secret}"
export AWS_PAGER=""
ACCOUNT_ID="000000000000"
UI_URL="${UI_URL:-http://localhost:4500}"

# --------------------------------------------------------------------- nomes
VPC_NAME="vpc-$ENVIRONMENT-$PRODUCT-$REGION_SHORT"
IGW_NAME="igw-$ENVIRONMENT-$PRODUCT-$REGION_SHORT"
NAT_NAME="nat-$ENVIRONMENT-$PRODUCT-$REGION_SHORT"
CLUSTER="eks-$ENVIRONMENT-$PRODUCT-$REGION_SHORT"
DB_ID="rds-$ENVIRONMENT-$PRODUCT-$REGION_SHORT"
DB_SUBNET_GROUP="dbsng-$ENVIRONMENT-$PRODUCT-$REGION_SHORT"
BASTION_NAME="ec2-$ENVIRONMENT-$PRODUCT-bastion-1a"
BUCKET="$PRODUCT-$ENVIRONMENT-frontend-$AWS_DEFAULT_REGION"
API_NAME="api-$ENVIRONMENT-$PRODUCT-$REGION_SHORT"
API_STAGE="$ENVIRONMENT"

# Banco: usuário de aplicação, não "admin".
DB_NAME="shielddb"
DB_USER="shield_app"
DB_PASS="Sh1eld-L0cal-Dev"          # laboratório local; em AWS real viria do Secrets Manager
DB_ANON_ROLE="shield_web_anon"       # role somente-leitura exposta pela API

# KMS: uma chave por domínio de dado, como se faz em produção.
KMS_EBS_ALIAS="alias/$ENVIRONMENT-$PRODUCT-ebs"
KMS_RDS_ALIAS="alias/$ENVIRONMENT-$PRODUCT-rds"
KMS_S3_ALIAS="alias/$ENVIRONMENT-$PRODUCT-s3"

# IAM
ROLE_EKS_CLUSTER="role-$ENVIRONMENT-$PRODUCT-eks-cluster"
ROLE_EKS_NODE="role-$ENVIRONMENT-$PRODUCT-eks-node"
ROLE_BASTION="role-$ENVIRONMENT-$PRODUCT-bastion"
ROLE_APIGW_S3="role-$ENVIRONMENT-$PRODUCT-apigw-s3"
PROFILE_BASTION="instprof-$ENVIRONMENT-$PRODUCT-bastion"

# Rede: 3 AZs × 3 camadas (pública / app privada / dados privada).
VPC_CIDR="10.20.0.0/16"
AZS=(a b c)
PUB_CIDRS=(10.20.0.0/24 10.20.1.0/24 10.20.2.0/24)
APP_CIDRS=(10.20.10.0/24 10.20.11.0/24 10.20.12.0/24)
DATA_CIDRS=(10.20.20.0/24 10.20.21.0/24 10.20.22.0/24)

# Imagens / portas
PG_IMAGE="postgres:16-alpine"
BACKEND_IMAGE="postgrest/postgrest:v12.2.3"
BACKEND_NODEPORT=30300

# ----------------------------------------------------------------------- tags
# Aplicadas em todos os recursos. Em produção é o que sustenta billing por
# centro de custo, inventário e políticas de acesso baseadas em tag.
BASE_TAGS=(
  "Environment=$ENVIRONMENT"
  "Project=$PRODUCT"
  "Owner=squad-pagamentos"
  "CostCenter=CC-4471"
  "Compliance=pci-dss"
  "ManagedBy=floci-lab"
)

# --tag-specifications do EC2: ec2_tagspec <resource-type> <name> [K=V ...]
ec2_tagspec() {
  local rt="$1" name="$2"; shift 2
  local t="{Key=Name,Value=$name}" kv
  for kv in "${BASE_TAGS[@]}" "$@"; do t+=",{Key=${kv%%=*},Value=${kv#*=}}"; done
  printf 'ResourceType=%s,Tags=[%s]' "$rt" "$t"
}

# Formato "Key=k,Value=v ..." usado por RDS e KMS: kv_tags <name> [K=V ...]
kv_tags() {
  local name="$1"; shift
  printf 'Key=Name,Value=%s' "$name"
  local kv; for kv in "${BASE_TAGS[@]}" "$@"; do printf ' Key=%s,Value=%s' "${kv%%=*}" "${kv#*=}"; done
}

# KMS usa TagKey/TagValue em vez de Key/Value: kms_tags <name> [K=V ...]
kms_tags() {
  local name="$1"; shift
  printf 'TagKey=Name,TagValue=%s' "$name"
  local kv; for kv in "${BASE_TAGS[@]}" "$@"; do printf ' TagKey=%s,TagValue=%s' "${kv%%=*}" "${kv#*=}"; done
}

# Formato "k=v,k=v" usado por EKS e API Gateway: eq_tags <name> [K=V ...]
eq_tags() {
  local name="$1"; shift
  local out="Name=$name" kv
  for kv in "${BASE_TAGS[@]}" "$@"; do out+=",$kv"; done
  printf '%s' "$out"
}

# Formato TagSet do S3: s3_tagset <name> [K=V ...]
s3_tagset() {
  local name="$1"; shift
  local out="{Key=Name,Value=$name}" kv
  for kv in "${BASE_TAGS[@]}" "$@"; do out+=",{Key=${kv%%=*},Value=${kv#*=}}"; done
  printf 'TagSet=[%s]' "$out"
}

# --------------------------------------------------------------------- estado
STATE_DIR="$ROOT/.lab"
STATE="$STATE_DIR/state.env"
KUBECONFIG_FILE="$STATE_DIR/kubeconfig"

state_put() {
  mkdir -p "$STATE_DIR"; touch "$STATE"
  sed -i "/^${1}=/d" "$STATE"
  printf '%s=%s\n' "$1" "$2" >> "$STATE"
}
state_load() { [[ -f "$STATE" ]] && { set -a; . "$STATE"; set +a; }; return 0; }

# -------------------------------------------------------------------- helpers
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[36m'; DIM=$'\033[2m'; OFF=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$BLU" "$OFF" "$*"; }
step() { printf '\n%s### %s %s\n' "$BLU" "$*" "$OFF"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s  !!%s %s\n' "$YLW" "$OFF" "$*"; }
die()  { printf '%s ERRO%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' não encontrado no PATH."; }

floci_container() { docker compose -f "$ROOT/compose.yaml" ps -q floci | head -1; }
floci_network() {
  docker inspect "$(floci_container)" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'
}
api_base_url() { printf '%s/restapis/%s/%s/_user_request_' "$AWS_ENDPOINT_URL" "$1" "$API_STAGE"; }

# psql contra o RDS, sempre por container (o endpoint é IP da rede do Floci).
rds_psql() {
  state_load
  docker run --rm -i --network "$(floci_network)" -e PGPASSWORD="$DB_PASS" "$PG_IMAGE" \
    psql "host=$DB_ENDPOINT port=$DB_PORT user=$DB_USER dbname=$DB_NAME" "$@"
}
