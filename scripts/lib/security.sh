#!/usr/bin/env bash
# Camada de segurança: chaves KMS por domínio de dado e roles IAM por função.

# Cria (ou reaproveita) uma chave KMS com alias, rotação e tags.
# kms_ensure <alias> <descrição> <state-var>
kms_ensure() {
  local alias="$1" desc="$2" var="$3" arn
  if arn=$(aws kms describe-key --key-id "$alias" --query 'KeyMetadata.Arn' --output text 2>/dev/null); then
    state_put "$var" "$arn"; ok "KMS $alias (reaproveitada)"; return 0
  fi
  local kid
  kid=$(aws kms create-key --description "$desc" \
        --tags $(kms_tags "${alias#alias/}") \
        --query 'KeyMetadata.KeyId' --output text)
  aws kms create-alias --alias-name "$alias" --target-key-id "$kid" >/dev/null
  # Rotação anual: exigência recorrente de PCI-DSS/CIS para chaves de dado.
  aws kms enable-key-rotation --key-id "$kid" >/dev/null 2>&1 || warn "rotação não habilitada em $alias"
  arn=$(aws kms describe-key --key-id "$kid" --query 'KeyMetadata.Arn' --output text)
  state_put "$var" "$arn"
  ok "KMS $alias criada"
}

provision_kms() {
  step "KMS — uma chave por domínio de dado"
  kms_ensure "$KMS_EBS_ALIAS" "Volumes EBS do $PRODUCT ($ENVIRONMENT)" KMS_EBS_ARN
  kms_ensure "$KMS_RDS_ALIAS" "Banco RDS do $PRODUCT ($ENVIRONMENT)"   KMS_RDS_ARN
  kms_ensure "$KMS_S3_ALIAS"  "Bucket de frontend do $PRODUCT ($ENVIRONMENT)" KMS_S3_ARN
  state_load

  # Criptografia de EBS ligada por padrão na conta/região, apontando para a
  # chave gerenciada pelo time — não para a aws/ebs default.
  aws ec2 enable-ebs-encryption-by-default >/dev/null 2>&1 \
    && ok "EBS: criptografia por padrão habilitada" \
    || warn "não consegui habilitar EBS encryption by default"
  aws ec2 modify-ebs-default-kms-key-id --kms-key-id "$KMS_EBS_ARN" >/dev/null 2>&1 \
    && ok "EBS: chave padrão = $KMS_EBS_ALIAS" \
    || warn "não consegui definir a chave padrão de EBS"
}

# iam_role <nome> <serviço-principal> <descrição>
iam_role() {
  local name="$1" svc="$2" desc="$3"
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then ok "IAM $name (existente)"; return 0; fi
  aws iam create-role --role-name "$name" --description "$desc" \
    --assume-role-policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$svc\"},\"Action\":\"sts:AssumeRole\"}]}" >/dev/null
  aws iam tag-role --role-name "$name" --tags $(kv_tags "$name") >/dev/null 2>&1 || true
  ok "IAM $name criada"
}

provision_iam() {
  step "IAM — uma role por função, sem credencial estática"
  state_load

  iam_role "$ROLE_EKS_CLUSTER" "eks.amazonaws.com" "Control plane do $CLUSTER"
  iam_role "$ROLE_EKS_NODE"    "ec2.amazonaws.com" "Nodes do $CLUSTER"
  iam_role "$ROLE_BASTION"     "ec2.amazonaws.com" "Bastion $BASTION_NAME"
  iam_role "$ROLE_APIGW_S3"    "apigateway.amazonaws.com" "API Gateway lendo o bucket de frontend"

  # Bastion: só acesso via SSM e leitura do segredo do banco. Sem chave SSH.
  aws iam put-role-policy --role-name "$ROLE_BASTION" --policy-name "bastion-minima" \
    --policy-document '{
      "Version":"2012-10-17",
      "Statement":[
        {"Sid":"SessionManager","Effect":"Allow",
         "Action":["ssm:UpdateInstanceInformation","ssmmessages:*","ec2messages:*"],"Resource":"*"},
        {"Sid":"LogsWrite","Effect":"Allow",
         "Action":["logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}]}' >/dev/null
  ok "policy inline: bastion-minima"

  # API Gateway lê objetos do bucket privado e usa a chave KMS do S3 —
  # é isso que permite manter Block Public Access ligado no bucket.
  aws iam put-role-policy --role-name "$ROLE_APIGW_S3" --policy-name "apigw-frontend-read" \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[
        {\"Sid\":\"ReadFrontend\",\"Effect\":\"Allow\",
         \"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},
        {\"Sid\":\"DecryptWithCmk\",\"Effect\":\"Allow\",
         \"Action\":[\"kms:Decrypt\"],\"Resource\":\"$KMS_S3_ARN\"}]}" >/dev/null
  ok "policy inline: apigw-frontend-read"

  # Nodes do EKS: acesso ao ECR e à chave do EBS (volumes dos pods).
  aws iam put-role-policy --role-name "$ROLE_EKS_NODE" --policy-name "node-ecr-ebs" \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[
        {\"Effect\":\"Allow\",\"Action\":[\"ecr:GetAuthorizationToken\",\"ecr:BatchGetImage\",
          \"ecr:GetDownloadUrlForLayer\"],\"Resource\":\"*\"},
        {\"Effect\":\"Allow\",\"Action\":[\"kms:CreateGrant\",\"kms:Decrypt\",
          \"kms:GenerateDataKeyWithoutPlainText\"],\"Resource\":\"$KMS_EBS_ARN\"}]}" >/dev/null
  ok "policy inline: node-ecr-ebs"

  # Instance profile é o que liga a role à instância EC2.
  aws iam create-instance-profile --instance-profile-name "$PROFILE_BASTION" >/dev/null 2>&1 || true
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_BASTION" \
    --role-name "$ROLE_BASTION" >/dev/null 2>&1 || true
  ok "instance profile: $PROFILE_BASTION"

  state_put ROLE_EKS_CLUSTER_ARN "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_EKS_CLUSTER"
  state_put ROLE_APIGW_S3_ARN    "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_APIGW_S3"
}
