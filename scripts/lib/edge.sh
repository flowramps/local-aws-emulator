#!/usr/bin/env bash
# Borda: bucket S3 privado com o frontend + API Gateway como única porta de entrada.

provision_s3() {
  step "S3 — bucket do frontend, privado e cifrado com $KMS_S3_ALIAS"
  state_load

  aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || \
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  ok "bucket $BUCKET"

  # Criptografia em repouso com chave do time + Bucket Key (reduz chamadas KMS).
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration "{\"Rules\":[{
      \"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_S3_ARN\"},
      \"BucketKeyEnabled\":true}]}" >/dev/null
  ok "SSE-KMS ($KMS_S3_ALIAS) + bucket key"

  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled >/dev/null
  ok "versionamento habilitado (rollback de deploy do frontend)"

  # ACL: o pedido é explicitamente "private". Com BucketOwnerEnforced as ACLs
  # ficam desativadas e o acesso passa a ser só por policy — que é a
  # recomendação atual da AWS. Aqui usamos BucketOwnerPreferred para que a ACL
  # continue existindo e ser inspecionável no laboratório.
  aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerPreferred}]' >/dev/null
  aws s3api put-bucket-acl --bucket "$BUCKET" --acl private >/dev/null
  ok "ACL do bucket: private (ownership=BucketOwnerPreferred)"

  # Block Public Access nos quatro eixos: nenhum objeto vira público por
  # acidente, nem via ACL nem via policy.
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
  ok "Block Public Access: os 4 flags ligados"

  # Quem lê o bucket é a role do API Gateway — ninguém mais.
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Sid\":\"SomenteApiGateway\",\"Effect\":\"Allow\",
       \"Principal\":{\"AWS\":\"$ROLE_APIGW_S3_ARN\"},
       \"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},
      {\"Sid\":\"NegarTransporteInseguro\",\"Effect\":\"Deny\",
       \"Principal\":\"*\",\"Action\":\"s3:*\",
       \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"],
       \"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}" >/dev/null
  ok "bucket policy: só a role do API Gateway + deny em tráfego não-TLS"

  aws s3api put-bucket-tagging --bucket "$BUCKET" \
    --tagging "$(s3_tagset "$BUCKET" "DataClassification=public-content")" >/dev/null
  ok "tags aplicadas"

  aws s3api put-bucket-website --bucket "$BUCKET" \
    --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"}}' >/dev/null
  ok "website config (index.html / error.html)"

  # Publica o frontend. Cada objeto sobe com ACL private explícita.
  local f key ct
  for f in "$ROOT"/frontend/*; do
    key="$(basename "$f")"
    case "$key" in
      *.html) ct="text/html; charset=utf-8" ;;
      *.css)  ct="text/css" ;;
      *.js)   ct="application/javascript" ;;
      *)      ct="application/octet-stream" ;;
    esac
    aws s3api put-object --bucket "$BUCKET" --key "$key" --body "$f" \
      --content-type "$ct" --acl private >/dev/null
  done
  ok "frontend publicado: $(ls "$ROOT"/frontend | tr '\n' ' ')"
}

provision_apigw() {
  step "API Gateway — porta única: frontend do S3 + API do EKS"
  state_load

  local api
  api=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text 2>/dev/null)
  if [[ -z "$api" || "$api" == "None" ]]; then
    api=$(aws apigateway create-rest-api --name "$API_NAME" \
      --description "Entrada única do $PRODUCT ($ENVIRONMENT)" \
      --tags "$(eq_tags "$API_NAME")" \
      --query 'id' --output text)
  fi
  state_put API_ID "$api"
  ok "REST API $API_NAME ($api)"

  local root
  root=$(aws apigateway get-resources --rest-api-id "$api" \
         --query "items[?path=='/'].id | [0]" --output text)

  # res_get_or_create <parent-id> <path-part> -> imprime o id
  res_get_or_create() {
    local parent="$1" part="$2" full id
    full=$(aws apigateway get-resources --rest-api-id "$api" \
           --query "items[?pathPart=='$part'&&parentId=='$parent'].id | [0]" --output text 2>/dev/null)
    if [[ -n "$full" && "$full" != "None" ]]; then printf '%s' "$full"; return; fi
    aws apigateway create-resource --rest-api-id "$api" --parent-id "$parent" \
      --path-part "$part" --query 'id' --output text
  }

  local s3_origin backend_origin
  # Origens vistas de dentro do container do Floci (é ele quem faz a chamada).
  s3_origin="http://floci:4566/$BUCKET"
  backend_origin="http://floci-eks-$CLUSTER:$BACKEND_NODEPORT"

  # --- GET / → index.html do bucket ------------------------------------------
  aws apigateway put-method --rest-api-id "$api" --resource-id "$root" \
    --http-method GET --authorization-type NONE >/dev/null 2>&1 || true
  aws apigateway put-integration --rest-api-id "$api" --resource-id "$root" \
    --http-method GET --type HTTP_PROXY --integration-http-method GET \
    --uri "$s3_origin/index.html" >/dev/null
  ok "GET /            → S3 $BUCKET/index.html"

  # --- ANY /api/{proxy+} → backend no EKS ------------------------------------
  # Declarado ANTES do catch-all: rota mais específica tem precedência.
  local r_api r_api_proxy
  r_api=$(res_get_or_create "$root" "api")
  r_api_proxy=$(res_get_or_create "$r_api" "{proxy+}")
  aws apigateway put-method --rest-api-id "$api" --resource-id "$r_api_proxy" \
    --http-method ANY --authorization-type NONE \
    --request-parameters 'method.request.path.proxy=true' >/dev/null 2>&1 || true
  aws apigateway put-integration --rest-api-id "$api" --resource-id "$r_api_proxy" \
    --http-method ANY --type HTTP_PROXY --integration-http-method ANY \
    --uri "$backend_origin/{proxy}" \
    --request-parameters 'integration.request.path.proxy=method.request.path.proxy' >/dev/null
  state_put API_RES_BACKEND "$r_api_proxy"
  ok "ANY /api/{proxy+} → EKS $CLUSTER:$BACKEND_NODEPORT"

  # --- ANY /{proxy+} → assets do bucket --------------------------------------
  local r_proxy
  r_proxy=$(res_get_or_create "$root" "{proxy+}")
  aws apigateway put-method --rest-api-id "$api" --resource-id "$r_proxy" \
    --http-method ANY --authorization-type NONE \
    --request-parameters 'method.request.path.proxy=true' >/dev/null 2>&1 || true
  aws apigateway put-integration --rest-api-id "$api" --resource-id "$r_proxy" \
    --http-method ANY --type HTTP_PROXY --integration-http-method ANY \
    --uri "$s3_origin/{proxy}" \
    --request-parameters 'integration.request.path.proxy=method.request.path.proxy' >/dev/null
  ok "ANY /{proxy+}    → S3 $BUCKET/{proxy}"

  aws apigateway create-deployment --rest-api-id "$api" --stage-name "$API_STAGE" \
    --description "deploy do laboratório" >/dev/null
  ok "stage $API_STAGE publicado"
  printf '\n  %sfrontend:%s %s/\n' "$GRN" "$OFF" "$(api_base_url "$api")"
  printf '  %sAPI:     %s %s/api/transacoes\n\n' "$GRN" "$OFF" "$(api_base_url "$api")"
}
