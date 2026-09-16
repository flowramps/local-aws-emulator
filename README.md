# Setup: Laboratório AWS local com Floci (WSL2 + Docker)

Ambiente de estudo para simular cenários de EC2, RDS, EKS e IAM localmente, usando o [Floci](https://github.com/floci-io/floci) como emulador de AWS, rodando via Docker dentro de uma distro WSL2 dedicada.

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

O CLI nativo (`curl -fsSL https://floci.io/install.sh | sh`) foi instalado, mas **não é usado** neste setup por incompatibilidade de CPU. Em vez de `floci start`, o servidor sobe direto pela imagem oficial:

```bash
mkdir -p ~/floci-lab && cd ~/floci-lab

cat > compose.yaml << 'EOF'
services:
  floci:
    image: floci/floci:latest
    ports:
      - "4566:4566"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

docker compose up -d
docker compose logs -f
```

Log de sucesso esperado:

```
=== AWS Local Emulator Ready ===
Ready.
... Listening on: http://0.0.0.0:4566
```

## 5. Configurar variáveis de ambiente do AWS CLI

Salvar em `~/floci-lab/env.sh`:

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
```

Carregar sempre que abrir um terminal novo:

```bash
source ~/floci-lab/env.sh
```

## 6. Teste de sanidade

```bash
curl http://localhost:4566/_localstack/health

aws s3 mb s3://teste-lab
aws s3 ls
```

Se o bucket `teste-lab` aparecer na listagem, o ambiente está pronto para os cenários de estudo (VPC, EC2, RDS, EKS, IAM).

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

## Notas / limitações conhecidas

- VPC, subnets e route tables no Floci funcionam como objetos de control-plane (a API responde corretamente), mas o isolamento de rede real entre eles pode não replicar 100% o comportamento de uma VPC AWS de verdade.
- RDS e EKS sobem containers Docker reais por trás (Postgres, k3s), então o comportamento desses dois é fiel ao real.
- O binário nativo do Floci CLI não é compatível com CPUs sem AVX2/FMA/BMI2 — usar sempre a imagem Docker (`floci/floci:latest`) nesse hardware.