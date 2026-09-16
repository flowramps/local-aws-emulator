#!/usr/bin/env bash
# EKS nas 3 subnets de app + o backend da aplicação rodando dentro do cluster.

provision_eks() {
  step "EKS — cluster privado nas 3 subnets de aplicação"
  state_load

  if ! aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
    aws eks create-cluster --name "$CLUSTER" \
      --role-arn "$ROLE_EKS_CLUSTER_ARN" \
      --kubernetes-version 1.31 \
      --resources-vpc-config "subnetIds=$SUBNET_APP_0,$SUBNET_APP_1,$SUBNET_APP_2,securityGroupIds=$SG_EKS,endpointPublicAccess=false,endpointPrivateAccess=true" \
      --encryption-config "resources=secrets,provider={keyArn=$KMS_EBS_ARN}" \
      --tags "$(eq_tags "$CLUSTER")" >/dev/null
  fi

  log "aguardando o cluster ficar ACTIVE"
  local i st=""
  for i in $(seq 1 60); do
    st=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.status' --output text 2>/dev/null || echo PENDING)
    [[ "$st" == "ACTIVE" ]] && break
    sleep 5
  done
  [[ "$st" == "ACTIVE" ]] || die "cluster não ficou ACTIVE (status=$st)"
  ok "EKS $CLUSTER ACTIVE em 3 AZs, endpoint privado"

  eks_kubeconfig
}

# O `aws eks update-kubeconfig` gera um contexto com exec plugin `aws eks
# get-token`, que o k3s por trás do Floci rejeita (401). Pegamos o kubeconfig
# interno do k3s e reapontamos o server para a porta publicada no host.
eks_kubeconfig() {
  need kubectl
  local c="floci-eks-$CLUSTER" port i
  docker ps --format '{{.Names}}' | grep -qx "$c" || die "container $c não está rodando"
  port=$(docker port "$c" 6443/tcp | head -1 | sed 's/.*://')
  [[ -n "$port" ]] || die "não descobri a porta publicada do API server"

  mkdir -p "$STATE_DIR"
  for i in $(seq 1 60); do
    docker exec "$c" cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_FILE" 2>/dev/null
    [[ -s "$KUBECONFIG_FILE" ]] && break
    sleep 2
  done
  [[ -s "$KUBECONFIG_FILE" ]] || die "k3s não gerou o kubeconfig a tempo"
  sed -i "s|https://127.0.0.1:6443|https://localhost:$port|" "$KUBECONFIG_FILE"
  chmod 600 "$KUBECONFIG_FILE"

  for i in $(seq 1 60); do
    KUBECONFIG="$KUBECONFIG_FILE" kubectl get --raw /readyz >/dev/null 2>&1 && break
    sleep 2
  done
  KUBECONFIG="$KUBECONFIG_FILE" kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1 \
    || warn "node não reportou Ready no tempo esperado"
  ok "kubeconfig isolado em $KUBECONFIG_FILE"
}

# Backend da aplicação: PostgREST expõe o schema `api` do RDS como REST.
# É o que faz o fluxo API Gateway → EKS → RDS devolver dado real.
deploy_backend() {
  step "Backend — API do $PRODUCT rodando no EKS"
  state_load
  export KUBECONFIG="$KUBECONFIG_FILE"

  kubectl create namespace "$PRODUCT" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # A senha entra como Secret; em AWS real viria do Secrets Manager via
  # External Secrets ou CSI driver, com a role do pod (IRSA) fazendo o acesso.
  kubectl -n "$PRODUCT" create secret generic shield-db \
    --from-literal=uri="postgres://$DB_USER:$DB_PASS@$DB_ENDPOINT:$DB_PORT/$DB_NAME" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "secret shield-db criado no namespace $PRODUCT"

  kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shield-api
  namespace: $PRODUCT
  labels: { app: shield-api, tier: backend }
spec:
  replicas: 1
  selector: { matchLabels: { app: shield-api } }
  template:
    metadata:
      labels: { app: shield-api, tier: backend }
    spec:
      containers:
        - name: postgrest
          image: $BACKEND_IMAGE
          ports: [{ containerPort: 3000 }]
          env:
            - name: PGRST_DB_URI
              valueFrom: { secretKeyRef: { name: shield-db, key: uri } }
            - name: PGRST_DB_SCHEMAS
              value: api
            - name: PGRST_DB_ANON_ROLE
              value: $DB_ANON_ROLE
            - name: PGRST_SERVER_PORT
              value: "3000"
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
---
apiVersion: v1
kind: Service
metadata:
  name: shield-api
  namespace: $PRODUCT
spec:
  type: ClusterIP           # a API não é exposta direto: quem publica é o ingress
  selector: { app: shield-api }
  ports: [{ port: 3000, targetPort: 3000 }]
YAML
  kubectl -n "$PRODUCT" rollout status deploy/shield-api --timeout=300s >/dev/null 2>&1 \
    || die "backend não subiu — 'kubectl -n $PRODUCT logs deploy/shield-api'"
  ok "shield-api pronto (ClusterIP, sem exposição direta)"

  deploy_ingress
}

# Ingress do cluster — o papel que um ALB Ingress Controller cumpriria numa EKS
# real: recebe o tráfego da borda, tira o prefixo /api e encaminha ao service.
#
# Aqui ele também contorna uma diferença do Floci: em recurso aninhado
# (/api/{proxy+}) o emulador substitui {proxy} pelo caminho COMPLETO
# ("api/transacoes"), não pelo trecho após o prefixo como a AWS faz. Com o
# strip acontecendo no cluster, a rota funciona igual nos dois mundos.
deploy_ingress() {
  export KUBECONFIG="$KUBECONFIG_FILE"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: shield-ingress
  namespace: $PRODUCT
data:
  default.conf: |
    server {
      listen 8080;
      # a barra final no proxy_pass é o que remove o prefixo /api/
      location /api/ { proxy_pass http://shield-api:3000/; }
      location = /healthz { return 200 "ok\n"; add_header Content-Type text/plain; }
      location / { return 404; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shield-ingress
  namespace: $PRODUCT
  labels: { app: shield-ingress, tier: edge }
spec:
  replicas: 1
  selector: { matchLabels: { app: shield-ingress } }
  template:
    metadata:
      labels: { app: shield-ingress, tier: edge }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ containerPort: 8080 }]
          volumeMounts:
            - { name: conf, mountPath: /etc/nginx/conf.d }
      volumes:
        - name: conf
          configMap: { name: shield-ingress }
---
apiVersion: v1
kind: Service
metadata:
  name: shield-ingress
  namespace: $PRODUCT
spec:
  type: NodePort
  selector: { app: shield-ingress }
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: $BACKEND_NODEPORT
YAML
  kubectl -n "$PRODUCT" rollout status deploy/shield-ingress --timeout=300s >/dev/null 2>&1 \
    || die "ingress não subiu — 'kubectl -n $PRODUCT logs deploy/shield-ingress'"
  ok "shield-ingress pronto (NodePort $BACKEND_NODEPORT, strip de /api)"
}
