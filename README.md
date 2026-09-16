# Setup: Laboratório AWS local com Floci (WSL2 + Docker)

Ambiente de estudo para simular cenários de EC2, RDS, EKS e IAM localmente, usando o [Floci](https://github.com/floci-io/floci) como emulador de AWS, rodando via Docker dentro de uma distro WSL2 dedicada.

> **Já tem Docker, AWS CLI e kubectl?** Pule para `make lab` — sobe o emulador e provisiona o estudo de caso inteiro (KMS, IAM, VPC 3 AZs, EC2, RDS, EKS, S3 + API Gateway), validando tudo em ~3 min. Depois, `make open` abre a aplicação. `make help` lista os alvos.
>
> A arquitetura, o diagrama e o passo a passo manual estão em [`fluxo-de-construcao.md`](fluxo-de-construcao.md).
>
> As seções 1 a 3 abaixo são o setup de máquina (WSL2 + Docker), feito uma vez só.

## Contexto e decisões tomadas

- A distro WSL original (Ubuntu 20.04) tinha glibc 2.31, incompatível com o binário nativo do Floci CLI (exigia GLIBC 2.32/2.34).
- Solução: instalar uma distro WSL2 nova e isolada com **Ubuntu 26.04 LTS**, sem afetar o ambiente 20.04 existente (que já tinha um cluster k3d + Postgres de outro projeto rodando).
- Mesmo na 26.04, o binário nativo do Floci CLI falhou por outro motivo: a CPU do host não possui os conjuntos de instrução `AVX2`, `FMA`, `BMI1/2`, `F16C`, exigidos pelo binário GraalVM native-image.
- Contorno: a **imagem Docker oficial do Floci** foi compilada com uma baseline de CPU mais conservadora e funciona normalmente — então o setup final usa `docker compose` em vez do CLI nativo (`floci start`).

## Pré-requisitos

- Windows 10/11 com WSL2 habilitado
- WSL atualizado (`wsl --update`) — necessário para reconhecer distros mais novas

## 1. Instalar a distro Ubuntu 26.04 no WSL2

O catálogo padrão do `wsl --install -d <nome>` não tinha as versões numeradas (só a entrada genérica `Ubuntu`, que estava desatualizada). Solução: baixar o pacote `.wsl` direto do site oficial.

1. Baixar em: https://ubuntu.com/download/wsl
2. Instalar via duplo clique no arquivo baixado, **ou** via PowerShell:

```powershell
wsl --install --from-file "C:\Users\Ramps\Downloads\ubuntu-26.04.1-wsl-amd64.wsl"
```

> Se o PowerShell reclamar que `--from-file` não existe, atualize o WSL primeiro:
> ```powershell
> wsl --update --web-download
> ```

3. Ao abrir a distro pela primeira vez, criar usuário/senha Unix.

4. Confirmar a versão instalada:

```bash
cat /etc/os-release
ldd --version | head -1
```

## 2. Instalar o Docker Engine dentro da distro

```bash
# Remove pacotes conflitantes antigos (se houver)
sudo apt-get remove docker docker-engine docker.io containerd runc

# Dependências
sudo apt-get update
sudo apt-get install -y ca-certificates curl

# Chave GPG oficial do Docker
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Repositório do Docker
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Instalação
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Permite rodar docker sem sudo
sudo usermod -aG docker $USER
```

> **Importante:** o grupo `docker` só é aplicado em sessões *novas* do terminal. Depois do `usermod`, rode `newgrp docker` ou feche e reabra o terminal antes de continuar.

## 3. Habilitar e iniciar o serviço Docker

```bash
sudo systemctl enable --now docker
```

Se `systemctl` não funcionar (systemd desabilitado nessa instância WSL), usar:

```bash
sudo service docker start
```

Validar:

```bash
docker ps
docker run hello-world
```

## 4. Subir o Floci via Docker Compose

O CLI nativo (`curl -fsSL https://floci.io/install.sh | sh`) foi instalado, mas **não é usado** neste setup por incompatibilidade de CPU. Em vez de `floci start`, o servidor sobe direto pela imagem oficial — o `compose.yaml` já está neste repositório e traz dois serviços:

```yaml
services:
  floci:
    image: floci/floci:latest
    ports:
      - "4566:4566"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  floci-ui:
    image: floci/floci-ui:latest
    ports:
      - "4500:4500"
    environment:
      FLOCI_ENDPOINT: http://floci:4566
      AWS_REGION: us-east-1
      AWS_ACCESS_KEY_ID: AKIALOCALSHIELD00000
      AWS_SECRET_ACCESS_KEY: shield-local-only-not-a-real-secret
    depends_on:
      floci:
        condition: service_healthy
```

```bash
docker compose up -d
docker compose logs -f
```

Ou, com espera automática até os dois responderem: `make up`.

| Porta | Serviço |
|---|---|
| `4566` | Endpoint AWS do Floci (é aqui que o `aws` CLI fala) |
| `4500` | Console web (Floci UI) |

> O bind do `docker.sock` não é detalhe: é por ele que o Floci sobe os containers reais de RDS (Postgres), EKS (k3s) e EC2 (sshd) no seu daemon Docker.

## 4.1. Console web (Floci UI)

Interface estilo AWS Console para navegar nos recursos criados: **http://localhost:4500** (ou `make ui`).

Dois detalhes que fazem a UI subir "vazia" se forem ignorados:

- **`FLOCI_ENDPOINT` precisa ser `http://floci:4566`, não `http://localhost:4566`.** Essa variável é resolvida *de dentro* do container da UI — `localhost` ali é o próprio container da UI, não o emulador. O nome do serviço do Compose resolve pela rede interna.
- **A imagem publicada já traz o backend compilado junto**, servindo UI e API na mesma porta `4500`. Só o build a partir do fonte separa a API na `4501` — não é preciso declarar um terceiro serviço.

Para checar sem abrir o navegador (a API é a mesma que a interface consome):

```bash
curl -s http://localhost:4500/api/ec2/vpcs      | jq .
curl -s http://localhost:4500/api/eks/clusters  | jq .
curl -s http://localhost:4500/api/clouds/aws/services/database/resources | jq .
```

O `make test` valida justamente isso: não só se a página responde, mas se a API embutida **enxerga** a VPC e o cluster do laboratório — que é o que prova que o `FLOCI_ENDPOINT` está certo.

Log de sucesso esperado:

```
=== AWS Local Emulator Ready ===
Ready.
... Listening on: http://0.0.0.0:4566
```

## 5. Configurar variáveis de ambiente do AWS CLI

O `env.sh` deste repositório já tem:

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=AKIALOCALSHIELD00000
export AWS_SECRET_ACCESS_KEY=shield-local-only-not-a-real-secret
```

> O Floci não valida assinatura — qualquer par de credenciais funciona. Usar um par identificável (em vez de `test`/`test`) evita confundir este ambiente com um profile real da AWS no histórico do shell, e deixa claro em qualquer log que a credencial é fictícia.

Carregar sempre que abrir um terminal novo:

```bash
source ./env.sh
```

Depois de `make provision`, use `eval "$(make -s env)"` — inclui também o `KUBECONFIG` isolado do laboratório (`.lab/kubeconfig`), sem mexer no seu `~/.kube/config`.

## 6. Teste de sanidade

```bash
curl http://localhost:4566/_localstack/health

aws s3 mb s3://teste-lab
aws s3 ls
```

Se o bucket `teste-lab` aparecer na listagem, o ambiente está pronto. Ele também deve aparecer no console em http://localhost:4500.

Para o cenário completo:

```bash
make lab      # provisiona e valida tudo
make open     # abre o painel do Shield
```

## Comandos úteis do dia a dia

```bash
# Parar o Floci
docker compose down

# Subir de novo
docker compose up -d

# Ver logs
docker compose logs -f

# Limpar tudo (inclusive dados persistidos, se houver volume)
docker compose down -v
```

Equivalentes via `make`: `make down` (para o Floci **e** remove os containers `floci-*` órfãos), `make up`, `make logs`, `make clean`.

> **`docker compose down` não basta.** Os containers de RDS, EKS e EC2 são criados pelo Floci direto no daemon, fora do Compose — eles ficam rodando depois do `down` e seguram a rede do projeto (`Resource is still in use`). Remova-os com `docker rm -f $(docker ps -aq --filter name=floci-)` ou use `make down`, que já faz isso.

## Notas / limitações conhecidas

- VPC, subnets e route tables no Floci funcionam como objetos de control-plane (a API responde corretamente), mas o isolamento de rede real entre eles não replica uma VPC AWS. Todos os containers ficam na mesma bridge do Compose.
- EC2, RDS e EKS sobem containers Docker reais por trás (sshd, Postgres, k3s), então o comportamento de processo desses três é fiel ao real — a topologia de rede entre eles, não.
- `aws eks update-kubeconfig` gera um contexto que **não autentica** no k3s por trás do Floci (401) e ainda troca o seu `current-context`. Use o kubeconfig interno do k3s — é o que o `make kubeconfig` faz.
- O endpoint do RDS é um IP da rede Docker do Floci (ex.: `172.20.0.2:7001`), não `localhost`. Em Docker Desktop/WSL com VM esse IP não é alcançável do host; rode o cliente dentro da mesma rede.
- Block Public Access e bucket policy são armazenados, mas **não aplicados**: o objeto continua legível anonimamente em `http://localhost:4566/<bucket>/<key>`.
- O binário nativo do Floci CLI não é compatível com CPUs sem AVX2/FMA/BMI2 — usar sempre a imagem Docker (`floci/floci:latest`) nesse hardware.

A lista completa, com as divergências de API Gateway, EKS e KMS observadas nos testes, está em [`fluxo-de-construcao.md`](fluxo-de-construcao.md#limitações-do-emulador).

## Estrutura do repositório

```
compose.yaml            # emulador (:4566) + console web (:4500)
env.sh                  # exports do AWS CLI apontando para o emulador
Makefile                # atalhos: make lab / open / test / clean
frontend/               # o SPA do Shield publicado no bucket S3
scripts/
  lab.sh                # orquestrador dos alvos do Makefile
  lib/common.sh         # convenção de nomes, tags padrão e estado
  lib/security.sh       # chaves KMS e roles IAM
  lib/net.sh            # VPC, 9 subnets, IGW, NAT, route tables, SGs
  lib/compute.sh        # EC2 bastion com EBS cifrado
  lib/data.sh           # RDS privado + schema da aplicação
  lib/k8s.sh            # EKS, kubeconfig, API e ingress
  lib/edge.sh           # bucket S3 privado e rotas do API Gateway
  lib/tests.sh          # validações de segurança, rede, tags e fluxo
fluxo-de-construcao.md  # arquitetura, diagramas e passo a passo manual
.lab/                   # estado gerado (IDs + kubeconfig) — ignorado pelo git
```