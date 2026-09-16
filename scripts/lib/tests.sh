#!/usr/bin/env bash
# Validações do ambiente. Cada check confere o efeito, não só o exit code do create.

FAILED=0
pass() { printf '%s  ok%s %s\n' "$GRN" "$OFF" "$*"; }
fail() { printf '%sfalhou%s %s\n' "$RED" "$OFF" "$*"; FAILED=$((FAILED+1)); }

# expect <descrição> <esperado> <obtido>
expect() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 — esperado '$2', obtido '$3'"; fi
}
# contains <descrição> <agulha> <palheiro>
contains() {
  if grep -q "$2" <<<"$3"; then pass "$1"; else fail "$1 — '$2' não encontrado"; fi
}

test_tags() {
  step "Tags — toda peça precisa ser rastreável"
  state_load
  local r n
  for r in "$VPC_ID" "$SUBNET_APP_0" "$SG_RDS" "$INSTANCE_ID" "$IGW_ID" "$NAT_ID" "$RTB_DATA"; do
    n=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$r" \
        --query "length(Tags[?Key=='Project'||Key=='CostCenter'||Key=='Environment'||Key=='Name'])" --output text 2>/dev/null)
    if [[ "$n" == "4" ]]; then pass "$r com Name/Project/Environment/CostCenter"
    else fail "$r tem só $n das 4 tags obrigatórias"; fi
  done
  contains "RDS $DB_ID etiquetado" "CostCenter" \
    "$(aws rds list-tags-for-resource --resource-name "arn:aws:rds:$AWS_DEFAULT_REGION:$ACCOUNT_ID:db:$DB_ID" --output text 2>&1)"
  contains "cluster $CLUSTER etiquetado" "CostCenter" \
    "$(aws eks describe-cluster --name "$CLUSTER" --query 'keys(cluster.tags)' --output text 2>&1)"
  contains "bucket $BUCKET etiquetado" "CostCenter" \
    "$(aws s3api get-bucket-tagging --bucket "$BUCKET" --output text 2>&1)"
}

test_kms() {
  step "KMS — chave por domínio, com rotação"
  state_load
  local a kid
  for a in "$KMS_EBS_ALIAS" "$KMS_RDS_ALIAS" "$KMS_S3_ALIAS"; do
    kid=$(aws kms describe-key --key-id "$a" --query 'KeyMetadata.KeyId' --output text 2>/dev/null) \
      && pass "$a existe" || { fail "$a não existe"; continue; }
    expect "$a com rotação anual" "True" \
      "$(aws kms get-key-rotation-status --key-id "$kid" --query 'KeyRotationEnabled' --output text 2>/dev/null)"
  done
  expect "EBS: criptografia por padrão" "True" \
    "$(aws ec2 get-ebs-encryption-by-default --query 'EbsEncryptionByDefault' --output text 2>/dev/null)"
  expect "EBS: chave padrão é a CMK do time" "$KMS_EBS_ARN" \
    "$(aws ec2 get-ebs-default-kms-key-id --query 'KmsKeyId' --output text 2>/dev/null)"
  expect "RDS cifrado" "True" \
    "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].StorageEncrypted' --output text)"
  expect "RDS usa a CMK de banco" "$KMS_RDS_ARN" \
    "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].KmsKeyId' --output text)"
  contains "S3 com SSE-KMS na CMK de frontend" "$KMS_S3_ARN" \
    "$(aws s3api get-bucket-encryption --bucket "$BUCKET" --output text 2>&1)"
}

test_iam() {
  step "IAM — roles por função"
  state_load
  local r
  for r in "$ROLE_EKS_CLUSTER" "$ROLE_EKS_NODE" "$ROLE_BASTION" "$ROLE_APIGW_S3"; do
    aws iam get-role --role-name "$r" >/dev/null 2>&1 && pass "role $r" || fail "role $r ausente"
  done
  contains "$ROLE_APIGW_S3 só lê o bucket do frontend" "$BUCKET" \
    "$(aws iam get-role-policy --role-name "$ROLE_APIGW_S3" --policy-name apigw-frontend-read --output text 2>&1)"
  contains "$ROLE_BASTION sem chave SSH, acesso por SSM" "ssmmessages" \
    "$(aws iam get-role-policy --role-name "$ROLE_BASTION" --policy-name bastion-minima --output text 2>&1)"
  contains "instance profile ligado ao bastion" "$ROLE_BASTION" \
    "$(aws iam get-instance-profile --instance-profile-name "$PROFILE_BASTION" --output text 2>&1)"
}

test_network() {
  step "Rede — 3 AZs, camadas separadas, rotas corretas"
  state_load
  expect "9 subnets na VPC" "9" \
    "$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'length(Subnets)' --output text)"
  expect "3 AZs distintas" "3" \
    "$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l)"
  contains "route table pública sai pelo IGW" "$IGW_ID" \
    "$(aws ec2 describe-route-tables --route-table-ids "$RTB_PUBLIC" --output text 2>&1)"
  contains "route table de app sai pelo NAT" "$NAT_ID" \
    "$(aws ec2 describe-route-tables --route-table-ids "$RTB_PRIVATE" --output text 2>&1)"
  local dflt
  dflt=$(aws ec2 describe-route-tables --route-table-ids "$RTB_DATA" \
         --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])" --output text)
  expect "camada de dados sem rota default" "0" "$dflt"

  # O SG do banco não pode ter nenhuma regra por CIDR — só por SG de origem.
  local cidrs
  cidrs=$(aws ec2 describe-security-groups --group-ids "$SG_RDS" \
          --query "length(SecurityGroups[0].IpPermissions[?length(IpRanges)>\`0\`])" --output text)
  expect "SG do RDS libera só por SG de origem (0 regras por CIDR)" "0" "$cidrs"
  contains "SG do bastion restrito ao CIDR do escritório" "203.0.113.0/24" \
    "$(aws ec2 describe-security-groups --group-ids "$SG_BASTION" --output text 2>&1)"
}

test_data() {
  step "Dados — RDS privado na camada certa"
  state_load
  expect "RDS não é publicamente acessível" "False" \
    "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].PubliclyAccessible' --output text)"
  expect "RDS no db subnet group do laboratório" "$DB_SUBNET_GROUP" \
    "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)"
  expect "retenção de backup de 7 dias" "7" \
    "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].BackupRetentionPeriod' --output text)"
  local n
  n=$(rds_psql -tAc "SELECT count(*) FROM api.transacoes;" 2>/dev/null | tr -d '[:space:]')
  expect "schema api.transacoes populado" "5" "$n"
}

test_s3_acl() {
  step "S3 — ACL privada e bloqueio público"
  state_load
  local pab
  pab=$(aws s3api get-public-access-block --bucket "$BUCKET" \
        --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
        --output text | tr -d '[:space:]')
  expect "Block Public Access nos 4 eixos" "TrueTrueTrueTrue" "$pab"

  # Nenhuma concessão para AllUsers/AuthenticatedUsers: o bucket é privado.
  local pub
  pub=$(aws s3api get-bucket-acl --bucket "$BUCKET" \
        --query "length(Grants[?Grantee.URI!=null && (contains(Grantee.URI,'AllUsers') || contains(Grantee.URI,'AuthenticatedUsers'))])" \
        --output text 2>/dev/null)
  expect "ACL sem concessão para AllUsers/AuthenticatedUsers" "0" "$pub"
  contains "bucket policy nega tráfego sem TLS" "SecureTransport" \
    "$(aws s3api get-bucket-policy --bucket "$BUCKET" --output text 2>&1)"
  contains "website config aponta index.html" "index.html" \
    "$(aws s3api get-bucket-website --bucket "$BUCKET" --output text 2>&1)"
  expect "versionamento habilitado" "Enabled" \
    "$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text)"
}

test_flow() {
  step "Fluxo ponta a ponta — navegador → API Gateway → {S3, EKS → RDS}"
  state_load
  local base; base=$(api_base_url "$API_ID")

  local html; html=$(curl -s --max-time 20 "$base/" 2>&1)
  contains "GET /  serve o frontend do bucket S3" "Shield · Antifraude" "$html"

  local asset; asset=$(curl -s --max-time 20 "$base/error.html" 2>&1)
  contains "GET /error.html  serve asset do bucket" "404" "$asset"

  local api; api=$(curl -s --max-time 30 "$base/api/transacoes" 2>&1)
  contains "GET /api/transacoes  chega no EKS e lê o RDS" "magalu-marketplace" "$api"

  # Prova que a rota /api/* tem precedência sobre o catch-all do S3:
  # se o catch-all vencesse, viria HTML do bucket em vez de JSON.
  local filtrado
  filtrado=$(curl -s --max-time 30 "$base/api/transacoes?status=eq.bloqueada&select=merchant" 2>&1)
  contains "filtro na API é repassado ao Postgres" "loja-desconhecida-xy" "$filtrado"
  if grep -q "<html" <<<"$api"; then fail "/api/* caiu no catch-all do S3"; else pass "/api/* tem precedência sobre /{proxy+}"; fi

  # O bucket é privado: leitura anônima direta tem de falhar.
  local direto
  direto=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
           "$AWS_ENDPOINT_URL/$BUCKET/index.html" 2>&1)
  if [[ "$direto" == "200" ]]; then
    warn "acesso anônimo direto ao objeto retornou 200 — o Floci não aplica bucket policy (ver README)"
  else
    pass "acesso anônimo direto ao objeto bloqueado ($direto)"
  fi
}

test_ui() {
  step "Console web"
  state_load
  contains "UI enxerga a VPC $VPC_ID" "$VPC_ID" "$(curl -sf --max-time 10 "$UI_URL/api/ec2/vpcs" 2>&1)"
  contains "UI enxerga o cluster $CLUSTER" "$CLUSTER" "$(curl -sf --max-time 10 "$UI_URL/api/eks/clusters" 2>&1)"
}

run_tests() {
  need docker; need kubectl
  state_load
  [[ -n "${VPC_ID:-}" ]] || die "sem estado — rode 'make provision'"
  test_kms; test_iam; test_network; test_tags; test_data; test_s3_acl; test_ui; test_flow
  echo
  if [[ $FAILED -eq 0 ]]; then
    printf '%s== todos os testes passaram ==%s\n' "$GRN" "$OFF"
  else
    printf '%s== %d teste(s) falharam ==%s\n' "$RED" "$FAILED" "$OFF"; return 1
  fi
}
