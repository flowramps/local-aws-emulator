#!/usr/bin/env bash
# RDS Postgres na camada de dados: privado, cifrado por CMK, multi-AZ subnets.

provision_rds() {
  step "RDS — Postgres privado, cifrado com $KMS_RDS_ALIAS"
  state_load

  # DB subnet group nas 3 subnets de dados: sem isso o RDS cai no grupo
  # default da VPC default e todo o desenho de rede vira decoração.
  if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
    aws rds create-db-subnet-group \
      --db-subnet-group-name "$DB_SUBNET_GROUP" \
      --db-subnet-group-description "Camada de dados do $PRODUCT ($ENVIRONMENT)" \
      --subnet-ids "$SUBNET_DATA_0" "$SUBNET_DATA_1" "$SUBNET_DATA_2" \
      --tags $(kv_tags "$DB_SUBNET_GROUP") >/dev/null
  fi
  ok "db subnet group $DB_SUBNET_GROUP (3 AZs)"

  if ! aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
    aws rds create-db-instance \
      --db-instance-identifier "$DB_ID" \
      --db-instance-class db.t3.micro \
      --engine postgres \
      --db-name "$DB_NAME" \
      --master-username "$DB_USER" --master-user-password "$DB_PASS" \
      --allocated-storage 20 --storage-type gp3 \
      --storage-encrypted --kms-key-id "$KMS_RDS_ARN" \
      --db-subnet-group-name "$DB_SUBNET_GROUP" \
      --vpc-security-group-ids "$SG_RDS" \
      --no-publicly-accessible \
      --backup-retention-period 7 \
      --copy-tags-to-snapshot \
      --auto-minor-version-upgrade \
      --deletion-protection \
      --tags $(kv_tags "$DB_ID" "DataClassification=restricted") >/dev/null
  fi

  local ep port
  ep=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
        --query 'DBInstances[0].Endpoint.Address' --output text)
  port=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
        --query 'DBInstances[0].Endpoint.Port' --output text)
  state_put DB_ENDPOINT "$ep"; state_put DB_PORT "$port"
  ok "RDS $DB_ID em $ep:$port (db=$DB_NAME user=$DB_USER)"

  local flags
  flags=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].[StorageEncrypted,PubliclyAccessible,BackupRetentionPeriod,DeletionProtection]' \
    --output text)
  ok "encrypted/public/backup/deletion-protection = $flags"
}

# Schema da aplicação + role anônima de leitura usada pela API.
seed_rds() {
  state_load
  log "aplicando schema do $PRODUCT no banco"
  rds_psql -v ON_ERROR_STOP=1 -q <<SQL || return 1
CREATE SCHEMA IF NOT EXISTS api;

CREATE TABLE IF NOT EXISTS api.transacoes (
  id          serial PRIMARY KEY,
  merchant    text        NOT NULL,
  valor       numeric(12,2) NOT NULL,
  moeda       text        NOT NULL DEFAULT 'BRL',
  score_risco int         NOT NULL,
  status      text        NOT NULL,
  criada_em   timestamptz NOT NULL DEFAULT now()
);

TRUNCATE api.transacoes RESTART IDENTITY;
INSERT INTO api.transacoes (merchant, valor, score_risco, status) VALUES
  ('magalu-marketplace',  199.90,  12, 'aprovada'),
  ('posto-ipiranga-4471', 320.00,  87, 'bloqueada'),
  ('netflix-brasil',       55.90,   3, 'aprovada'),
  ('loja-desconhecida-xy',1890.00, 96, 'bloqueada'),
  ('ifood-delivery',       74.30,  21, 'aprovada');

-- Role sem login, usada apenas pelo PostgREST para requisições anônimas:
-- a API nunca acessa o banco com o usuário dono do schema.
DROP ROLE IF EXISTS $DB_ANON_ROLE;
CREATE ROLE $DB_ANON_ROLE NOLOGIN;
GRANT USAGE ON SCHEMA api TO $DB_ANON_ROLE;
GRANT SELECT ON api.transacoes TO $DB_ANON_ROLE;
SQL
  ok "schema api.transacoes + role $DB_ANON_ROLE (somente SELECT)"
}
