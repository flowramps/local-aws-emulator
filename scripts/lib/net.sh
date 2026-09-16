#!/usr/bin/env bash
# Rede: VPC de 3 AZs com três camadas (pública, app privada, dados privada).

provision_net() {
  step "Rede — VPC 3 AZs × 3 camadas"
  state_load

  # ---------------------------------------------------------------- VPC + IGW
  if [[ -z "${VPC_ID:-}" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(ec2_tagspec vpc "$VPC_NAME")" \
      --query 'Vpc.VpcId' --output text)
    state_put VPC_ID "$VPC_ID"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames >/dev/null 2>&1 || true
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support   >/dev/null 2>&1 || true
  fi
  ok "VPC $VPC_NAME ($VPC_ID) $VPC_CIDR"

  if [[ -z "${IGW_ID:-}" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
      --tag-specifications "$(ec2_tagspec internet-gateway "$IGW_NAME")" \
      --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null
    state_put IGW_ID "$IGW_ID"
  fi
  ok "Internet Gateway $IGW_ID"

  # -------------------------------------------------------------- 9 subnets
  # Camada separada para dados (não só "privada") porque RDS e EKS têm
  # requisitos de blast radius diferentes: o banco nunca deve compartilhar
  # route table/NACL com workload de aplicação.
  local i az sid tier cidr
  for tier in pub app data; do
    for i in 0 1 2; do
      az="$AWS_DEFAULT_REGION${AZS[$i]}"
      local var="SUBNET_${tier^^}_${i}"
      [[ -n "${!var:-}" ]] && continue
      case "$tier" in
        pub)  cidr="${PUB_CIDRS[$i]}" ;;
        app)  cidr="${APP_CIDRS[$i]}" ;;
        data) cidr="${DATA_CIDRS[$i]}" ;;
      esac
      local name="snet-$ENVIRONMENT-$PRODUCT-$tier-${AZS[$i]}"
      # Tags kubernetes.io/role/*: é assim que o EKS descobre onde criar
      # load balancers públicos (elb) e internos (internal-elb).
      local extra=("Tier=$tier")
      [[ "$tier" == "pub" ]] && extra+=("kubernetes.io/role/elb=1")
      [[ "$tier" == "app" ]] && extra+=("kubernetes.io/role/internal-elb=1")
      sid=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
        --availability-zone "$az" \
        --tag-specifications "$(ec2_tagspec subnet "$name" "${extra[@]}")" \
        --query 'Subnet.SubnetId' --output text)
      [[ "$tier" == "pub" ]] && aws ec2 modify-subnet-attribute --subnet-id "$sid" --map-public-ip-on-launch >/dev/null 2>&1
      state_put "$var" "$sid"
    done
  done
  state_load
  ok "subnets públicas:  $SUBNET_PUB_0 $SUBNET_PUB_1 $SUBNET_PUB_2"
  ok "subnets app (EKS): $SUBNET_APP_0 $SUBNET_APP_1 $SUBNET_APP_2"
  ok "subnets dados:     $SUBNET_DATA_0 $SUBNET_DATA_1 $SUBNET_DATA_2"

  # ------------------------------------------------------------ NAT Gateway
  # Um único NAT para manter o laboratório barato. Em produção seriam três,
  # um por AZ — com um só, a queda daquela AZ derruba a saída das outras duas.
  if [[ -z "${NAT_ID:-}" ]]; then
    EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "$(ec2_tagspec elastic-ip "eip-$ENVIRONMENT-$PRODUCT-nat")" \
      --query 'AllocationId' --output text)
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$SUBNET_PUB_0" --allocation-id "$EIP_ALLOC" \
      --tag-specifications "$(ec2_tagspec natgateway "$NAT_NAME")" \
      --query 'NatGateway.NatGatewayId' --output text)
    state_put EIP_ALLOC "$EIP_ALLOC"; state_put NAT_ID "$NAT_ID"
  fi
  ok "NAT Gateway $NAT_ID (na $SUBNET_PUB_0)"

  # ----------------------------------------------------------- route tables
  if [[ -z "${RTB_PUBLIC:-}" ]]; then
    RTB_PUBLIC=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(ec2_tagspec route-table "rtb-$ENVIRONMENT-$PRODUCT-public")" \
      --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$RTB_PUBLIC" --destination-cidr-block 0.0.0.0/0 \
      --gateway-id "$IGW_ID" >/dev/null
    for i in 0 1 2; do
      local v="SUBNET_PUB_$i"
      aws ec2 associate-route-table --route-table-id "$RTB_PUBLIC" --subnet-id "${!v}" >/dev/null
    done
    state_put RTB_PUBLIC "$RTB_PUBLIC"
  fi
  ok "route table pública → IGW"

  if [[ -z "${RTB_PRIVATE:-}" ]]; then
    RTB_PRIVATE=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(ec2_tagspec route-table "rtb-$ENVIRONMENT-$PRODUCT-private")" \
      --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$RTB_PRIVATE" --destination-cidr-block 0.0.0.0/0 \
      --nat-gateway-id "$NAT_ID" >/dev/null
    for i in 0 1 2; do
      local a="SUBNET_APP_$i"
      aws ec2 associate-route-table --route-table-id "$RTB_PRIVATE" --subnet-id "${!a}" >/dev/null
    done
    state_put RTB_PRIVATE "$RTB_PRIVATE"
  fi
  ok "route table privada (app) → NAT"

  # A camada de dados tem route table própria SEM rota default: o banco não
  # precisa de saída para a internet, nem para baixar pacote.
  if [[ -z "${RTB_DATA:-}" ]]; then
    RTB_DATA=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(ec2_tagspec route-table "rtb-$ENVIRONMENT-$PRODUCT-data")" \
      --query 'RouteTable.RouteTableId' --output text)
    for i in 0 1 2; do
      local d="SUBNET_DATA_$i"
      aws ec2 associate-route-table --route-table-id "$RTB_DATA" --subnet-id "${!d}" >/dev/null
    done
    state_put RTB_DATA "$RTB_DATA"
  fi
  ok "route table dados → sem rota default (isolada)"

  provision_security_groups
}

provision_security_groups() {
  step "Security Groups — liberação por identidade, não por CIDR"
  state_load

  # sg_new <var> <sufixo> <descrição>
  sg_new() {
    # Atenção: em `local a=$1 b=$a` o bash expande tudo antes de atribuir,
    # então o nome precisa ser montado numa instrução separada.
    local var="$1" suffix="$2" desc="$3"
    local name="sg-$ENVIRONMENT-$PRODUCT-$suffix"
    [[ -n "${!var:-}" ]] && return 0
    local id
    id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --tag-specifications "$(ec2_tagspec security-group "$name")" \
      --query 'GroupId' --output text)
    state_put "$var" "$id"
  }

  sg_new SG_BASTION bastion "Bastion - unico ponto de entrada administrativo"
  sg_new SG_EKS     eks     "Nodes e pods do cluster EKS"
  sg_new SG_RDS     rds     "Postgres - so aceita a camada de aplicacao"
  state_load

  # Bastion: SSH restrito ao CIDR corporativo. 0.0.0.0/0 aqui seria o achado
  # número um de qualquer auditoria.
  aws ec2 authorize-security-group-ingress --group-id "$SG_BASTION" \
    --protocol tcp --port 22 --cidr 203.0.113.0/24 >/dev/null 2>&1 || true
  ok "bastion: 22/tcp apenas de 203.0.113.0/24 (CIDR do escritório)"

  # EKS: recebe do bastion (debug) — o tráfego de usuário entra pelo API Gateway.
  aws ec2 authorize-security-group-ingress --group-id "$SG_EKS" \
    --protocol tcp --port 22 --source-group "$SG_BASTION" >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --group-id "$SG_EKS" \
    --protocol tcp --port 443 --source-group "$SG_BASTION" >/dev/null 2>&1 || true
  ok "eks: 22 e 443 apenas do SG do bastion"

  # RDS: 5432 só do SG do EKS (e do bastion, para troubleshooting). Nenhum CIDR.
  aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
    --protocol tcp --port 5432 --source-group "$SG_EKS" >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
    --protocol tcp --port 5432 --source-group "$SG_BASTION" >/dev/null 2>&1 || true
  ok "rds: 5432 apenas dos SGs de eks e bastion"
}
