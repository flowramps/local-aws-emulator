#!/usr/bin/env bash
# Orquestrador do laboratório Shield. Uso: ./scripts/lab.sh <comando> (ver `make help`)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/security.sh"
. "$ROOT/scripts/lib/net.sh"
. "$ROOT/scripts/lib/compute.sh"
. "$ROOT/scripts/lib/data.sh"
. "$ROOT/scripts/lib/k8s.sh"
. "$ROOT/scripts/lib/edge.sh"
. "$ROOT/scripts/lib/tests.sh"

# ---------------------------------------------------------------- up / down

cmd_up() {
  need docker; need aws; need curl
  log "subindo Floci + console web"
  docker compose -f "$ROOT/compose.yaml" up -d
  local i ready=0
  for i in $(seq 1 60); do
    curl -sf "$AWS_ENDPOINT_URL/_localstack/health" >/dev/null 2>&1 && { ready=1; break; }
    sleep 2
  done
  [[ $ready -eq 1 ]] || die "Floci não respondeu em 120s — veja 'make logs'"
  ok "emulador pronto em $AWS_ENDPOINT_URL"
  for i in $(seq 1 30); do
    curl -sf "$UI_URL/api/clouds/aws/status" >/dev/null 2>&1 && { ok "console web em $UI_URL"; return 0; }
    sleep 2
  done
  warn "console web não respondeu em 60s (o resto do laboratório funciona)"
}

cmd_down() {
  log "parando o ambiente"
  docker compose -f "$ROOT/compose.yaml" down
  # RDS/EKS/EC2/ECR são criados pelo Floci fora do Compose.
  local leftovers; leftovers=$(docker ps -aq --filter "name=floci-" || true)
  [[ -n "$leftovers" ]] && { warn "removendo containers órfãos do Floci"; docker rm -f $leftovers >/dev/null; }
  rm -rf "$STATE_DIR"
  ok "ambiente parado e estado local limpo"
}

cmd_logs() { docker compose -f "$ROOT/compose.yaml" logs -f; }

# ------------------------------------------------------------- provisionamento

cmd_provision() {
  need aws; need docker; need kubectl
  mkdir -p "$STATE_DIR"
  curl -sf "$AWS_ENDPOINT_URL/_localstack/health" >/dev/null || die "Floci não está no ar — rode 'make up'"
  provision_kms
  provision_iam
  provision_net
  provision_ec2
  provision_rds
  seed_rds
  provision_eks
  deploy_backend
  provision_s3
  provision_apigw
}

# ---------------------------------------------------------------------- extras

cmd_url() { state_load; api_base_url "$API_ID"; echo; }

cmd_open() {
  state_load
  local u; u="$(api_base_url "$API_ID")/"
  echo "$u"
  command -v xdg-open >/dev/null 2>&1 && xdg-open "$u" >/dev/null 2>&1 &
  true
}

cmd_ui() {
  echo "$UI_URL"
  command -v xdg-open >/dev/null 2>&1 && xdg-open "$UI_URL" >/dev/null 2>&1 &
  true
}

cmd_psql() {
  state_load
  [[ -n "${DB_ENDPOINT:-}" ]] || die "sem estado — rode 'make provision'"
  docker run --rm -it --network "$(floci_network)" -e PGPASSWORD="$DB_PASS" "$PG_IMAGE" \
    psql "host=$DB_ENDPOINT port=$DB_PORT user=$DB_USER dbname=$DB_NAME"
}

cmd_ssh() {
  state_load
  local c="floci-ec2-${INSTANCE_ID:-}"
  docker ps --format '{{.Names}}' | grep -qx "$c" || die "bastion não está rodando"
  docker exec -it "$c" sh
}

cmd_status() {
  state_load
  printf '\n%s Plataforma %s\n' "$BLU" "$OFF"
  printf '  produto   %s (%s) · conta %s · %s\n' "$PRODUCT" "$ENVIRONMENT" "$ACCOUNT_ID" "$AWS_DEFAULT_REGION"
  curl -sf "$AWS_ENDPOINT_URL/_localstack/health" >/dev/null 2>&1 \
    && echo "  emulador  $AWS_ENDPOINT_URL  (no ar)" || echo "  emulador  $AWS_ENDPOINT_URL  (fora do ar)"
  curl -sf "$UI_URL/api/clouds/aws/status" >/dev/null 2>&1 \
    && echo "  console   $UI_URL  (no ar)" || echo "  console   $UI_URL  (fora do ar)"
  [[ -n "${API_ID:-}" ]] && printf '  aplicação %s/\n' "$(api_base_url "$API_ID")"

  if [[ -f "$STATE" ]]; then
    printf '\n%s Recursos %s\n' "$BLU" "$OFF"
    printf '  %-14s %s\n' \
      "VPC"        "$VPC_NAME  ${VPC_ID:--}  $VPC_CIDR" \
      "subnets"    "pub ${SUBNET_PUB_0:--} ${SUBNET_PUB_1:--} ${SUBNET_PUB_2:--}" \
      ""           "app ${SUBNET_APP_0:--} ${SUBNET_APP_1:--} ${SUBNET_APP_2:--}" \
      ""           "data ${SUBNET_DATA_0:--} ${SUBNET_DATA_1:--} ${SUBNET_DATA_2:--}" \
      "gateways"   "igw ${IGW_ID:--}  nat ${NAT_ID:--}" \
      "sec groups" "bastion ${SG_BASTION:--}  eks ${SG_EKS:--}  rds ${SG_RDS:--}" \
      "KMS"        "$KMS_EBS_ALIAS  $KMS_RDS_ALIAS  $KMS_S3_ALIAS" \
      "EC2"        "$BASTION_NAME  ${INSTANCE_ID:--}" \
      "RDS"        "$DB_ID  ${DB_ENDPOINT:--}:${DB_PORT:--}" \
      "EKS"        "$CLUSTER" \
      "S3"         "$BUCKET" \
      "API GW"     "$API_NAME  ${API_ID:--}"
  else
    printf '\n  (sem recursos — rode %smake provision%s)\n' "$DIM" "$OFF"
  fi

  printf '\n%s Containers %s\n' "$BLU" "$OFF"
  docker ps --filter "name=floci" --format '  {{.Names}}\t{{.Status}}' || true
  if [[ -f "$KUBECONFIG_FILE" ]]; then
    printf '\n%s Kubernetes %s\n' "$BLU" "$OFF"
    KUBECONFIG="$KUBECONFIG_FILE" kubectl -n "$PRODUCT" get deploy,svc 2>/dev/null | sed 's/^/  /' \
      || echo "  (cluster fora do ar)"
  fi
  echo
}

cmd_env() {
  cat <<EOF
export AWS_ENDPOINT_URL=$AWS_ENDPOINT_URL
export AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export KUBECONFIG=$KUBECONFIG_FILE
EOF
}

# Ordem inversa das dependências.
cmd_destroy() {
  state_load
  step "Removendo os recursos"
  [[ -n "${API_ID:-}" ]] && aws apigateway delete-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1 && ok "API Gateway" || true
  aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 && ok "bucket $BUCKET" || true
  aws eks delete-cluster --name "$CLUSTER" >/dev/null 2>&1 && ok "EKS $CLUSTER" || true
  # deletion-protection precisa cair antes do delete.
  aws rds modify-db-instance --db-instance-identifier "$DB_ID" --no-deletion-protection --apply-immediately >/dev/null 2>&1 || true
  aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot >/dev/null 2>&1 && ok "RDS $DB_ID" || true
  aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1 || true
  [[ -n "${INSTANCE_ID:-}" ]] && aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 && ok "EC2 bastion" || true
  [[ -n "${NAT_ID:-}" ]] && aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" >/dev/null 2>&1 && ok "NAT gateway" || true
  [[ -n "${EIP_ALLOC:-}" ]] && aws ec2 release-address --allocation-id "$EIP_ALLOC" >/dev/null 2>&1 || true
  [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
  [[ -n "${IGW_ID:-}" ]] && aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" >/dev/null 2>&1 && ok "internet gateway" || true
  local v
  for v in SG_RDS SG_EKS SG_BASTION; do
    [[ -n "${!v:-}" ]] && aws ec2 delete-security-group --group-id "${!v}" >/dev/null 2>&1 || true
  done
  ok "security groups"
  for v in RTB_DATA RTB_PRIVATE RTB_PUBLIC; do
    [[ -n "${!v:-}" ]] && aws ec2 delete-route-table --route-table-id "${!v}" >/dev/null 2>&1 || true
  done
  ok "route tables"
  local t i
  for t in PUB APP DATA; do for i in 0 1 2; do
    v="SUBNET_${t}_${i}"
    [[ -n "${!v:-}" ]] && aws ec2 delete-subnet --subnet-id "${!v}" >/dev/null 2>&1 || true
  done; done
  ok "subnets"
  [[ -n "${VPC_ID:-}" ]] && aws ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null 2>&1 && ok "VPC" || true

  local r
  for r in "$ROLE_EKS_CLUSTER" "$ROLE_EKS_NODE" "$ROLE_BASTION" "$ROLE_APIGW_S3"; do
    aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
  done
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_BASTION" >/dev/null 2>&1 || true
  ok "roles IAM"
  for r in "$KMS_EBS_ALIAS" "$KMS_RDS_ALIAS" "$KMS_S3_ALIAS"; do
    aws kms delete-alias --alias-name "$r" >/dev/null 2>&1 || true
  done
  ok "aliases KMS"
  rm -rf "$STATE_DIR"
  ok "estado local removido"
}

case "${1:-}" in
  up)         cmd_up ;;
  down)       cmd_down ;;
  logs)       cmd_logs ;;
  provision)  cmd_provision ;;
  kubeconfig) state_load; eks_kubeconfig ;;
  backend)    deploy_backend ;;
  frontend)   provision_s3; provision_apigw ;;
  seed)       seed_rds ;;
  test)       run_tests ;;
  flow)       state_load; FAILED=0; test_flow; [[ $FAILED -eq 0 ]] ;;
  url)        cmd_url ;;
  open)       cmd_open ;;
  ui)         cmd_ui ;;
  psql)       cmd_psql ;;
  ssh)        cmd_ssh ;;
  status)     cmd_status ;;
  env)        cmd_env ;;
  destroy)    cmd_destroy ;;
  *) die "comando desconhecido: '${1:-}' — veja 'make help'" ;;
esac
