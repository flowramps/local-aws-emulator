#!/usr/bin/env bash
# EC2 bastion: único ponto de entrada administrativo, com EBS criptografado.

provision_ec2() {
  step "EC2 — bastion na subnet pública, volume cifrado por CMK"
  state_load

  if [[ -z "${INSTANCE_ID:-}" ]]; then
    INSTANCE_ID=$(aws ec2 run-instances --image-id ami-00000001 --count 1 \
      --instance-type t3.micro \
      --subnet-id "$SUBNET_PUB_0" \
      --security-group-ids "$SG_BASTION" \
      --iam-instance-profile "Name=$PROFILE_BASTION" \
      --block-device-mappings "[{
        \"DeviceName\":\"/dev/xvda\",
        \"Ebs\":{\"VolumeSize\":20,\"VolumeType\":\"gp3\",
                 \"Encrypted\":true,\"KmsKeyId\":\"$KMS_EBS_ARN\",
                 \"DeleteOnTermination\":true}}]" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --tag-specifications "$(ec2_tagspec instance "$BASTION_NAME" "Tier=pub")" \
      --query 'Instances[0].InstanceId' --output text)
    state_put INSTANCE_ID "$INSTANCE_ID"
  fi
  ok "bastion $BASTION_NAME ($INSTANCE_ID)"
  ok "IMDSv2 obrigatório (HttpTokens=required)"

  local enc
  enc=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.[VolumeId,Status]' \
        --output text 2>/dev/null || true)
  [[ -n "$enc" ]] && ok "volume raiz: $enc"
}
