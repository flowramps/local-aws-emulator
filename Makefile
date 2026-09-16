SHELL := /bin/bash
LAB   := ./scripts/lab.sh

.DEFAULT_GOAL := help
.PHONY: help up down logs provision kubeconfig backend frontend seed test flow \
        url open ui psql ssh status env destroy clean lab

help: ## Lista os alvos disponíveis
	@echo
	@echo "  Shield — plataforma antifraude em AWS emulada (Floci)"
	@echo "  VPC 3 AZs · EKS · RDS · S3 + API Gateway · KMS · IAM"
	@echo
	@grep -hE '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-11s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Atalho:  make lab   (up + provision + test)"
	@echo

lab: up provision test ## Sobe o ambiente inteiro e valida ponta a ponta

up: ## Sobe o emulador (:4566) e o console web (:4500)
	@$(LAB) up

provision: ## Provisiona KMS, IAM, rede, EC2, RDS, EKS, S3 e API Gateway
	@$(LAB) provision

test: ## Roda todas as validações (segurança, rede, tags e fluxo)
	@$(LAB) test

flow: ## Só o fluxo ponta a ponta: API Gateway -> S3 e -> EKS -> RDS
	@$(LAB) flow

open: ## Abre o frontend do Shield no navegador
	@$(LAB) open

url: ## Imprime a URL base da aplicação
	@$(LAB) url

ui: ## Abre o console web do emulador (http://localhost:4500)
	@$(LAB) ui

backend: ## Reimplanta só a API no EKS
	@$(LAB) backend

frontend: ## Republica o bucket S3 e as rotas do API Gateway
	@$(LAB) frontend

seed: ## Recria o schema e os dados de exemplo no RDS
	@$(LAB) seed

kubeconfig: ## Regenera .lab/kubeconfig a partir do k3s do cluster
	@$(LAB) kubeconfig

psql: ## Abre um shell psql no RDS
	@$(LAB) psql

ssh: ## Abre um shell dentro do container do bastion
	@$(LAB) ssh

status: ## Mostra o inventário do ambiente
	@$(LAB) status

env: ## Imprime os exports para usar aws/kubectl no seu shell
	@$(LAB) env

destroy: ## Remove os recursos AWS, mantendo o emulador no ar
	@$(LAB) destroy

down: ## Para o emulador e remove containers e estado local
	@$(LAB) down

logs: ## Acompanha os logs do emulador
	@$(LAB) logs

clean: destroy down ## destroy + down
