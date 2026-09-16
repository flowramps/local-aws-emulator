"""Diagrama de arquitetura do Shield com os ícones oficiais da AWS.

Gerado por `make diagram` (roda em container, não precisa instalar nada).
Fonte de verdade do desenho: editar aqui e rodar `make diagram`.
"""
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.network import APIGateway, InternetGateway, NATGateway, VPC
from diagrams.aws.security import KMS, IAMRole
from diagrams.aws.storage import S3
from diagrams.k8s.compute import Deploy
from diagrams.k8s.network import Ingress
from diagrams.onprem.client import Users

GRAPH = {
    "fontsize": "16",
    "fontname": "Helvetica",
    "pad": "0.6",
    "nodesep": "0.7",
    "ranksep": "1.2",
    "splines": "spline",
    "bgcolor": "white",
}
NODE = {"fontsize": "13", "fontname": "Helvetica"}
EDGE = {"fontsize": "12", "fontname": "Helvetica"}

with Diagram(
    "Shield · prd · us-east-1",
    filename="arquitetura",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=GRAPH,
    node_attr=NODE,
    edge_attr=EDGE,
):
    user = Users("Navegador")

    with Cluster("Borda — fora da VPC"):
        apigw = APIGateway("API Gateway\napi-prd-shield-us · prd")
        bucket = S3("shield-prd-frontend-us-east-1\nprivado · ACL private\nSSE-KMS · BPA 4/4")

    with Cluster("VPC vpc-prd-shield-us · 10.20.0.0/16 · 3 AZs"):

        with Cluster("Pública · 10.20.0-2.0/24"):
            bastion = EC2("bastion\nEBS cifrado · IMDSv2\nSSM · sem chave SSH")
            nat = NATGateway("NAT Gateway")
            igw = InternetGateway("Internet Gateway")

        with Cluster("Aplicação · 10.20.10-12.0/24 · EKS eks-prd-shield-us"):
            ing = Ingress("ingress\nstrip /api")
            api = Deploy("shield-api\nPostgREST · ClusterIP")

        with Cluster("Dados · 10.20.20-22.0/24 · sem rota default"):
            rds = RDSPostgresqlInstance(
                "rds-prd-shield-us\ncifrado prd-shield-rds\nprivado · backup 7d"
            )

    # Controles transversais: sem arestas de propósito. Ligá-los a cada recurso
    # cifrado/autorizado produz um emaranhado que atravessa o desenho inteiro —
    # a informação vive melhor nos labels dos próprios recursos e nas tabelas.
    with Cluster("Controles transversais — aplicados aos recursos acima"):
        kms = KMS("KMS · rotação anual\nprd-shield-ebs · prd-shield-rds\nprd-shield-s3")
        iam = IAMRole("IAM · uma role por função\neks-cluster · eks-node\nbastion · apigw-s3")

    # Caminho da requisição
    user >> Edge(label="GET /") >> apigw
    user >> Edge(label="GET /api/*") >> apigw
    apigw >> Edge(label="s3:GetObject\n+ kms:Decrypt") >> bucket
    apigw >> Edge(label="/api/*") >> ing
    ing >> api
    api >> Edge(label="5432 · só pelo SG do EKS") >> rds

    # Saída para a internet da camada de aplicação
    api >> Edge(label="egress", style="dashed", color="gray") >> nat
    nat >> igw

    # Sem nenhuma aresta o bastion flutua e estica a VPC; esta ancora ele no
    # mesmo rank da camada de aplicação, que é para onde ele de fato fala.
    bastion >> Edge(label="debug", style="dotted", color="gray") >> ing

    # Arestas invisíveis só para posicionar: sem elas o bloco de controles
    # flutua num canto e estica o desenho com espaço vazio.
    bucket >> Edge(style="invis") >> kms
    kms >> Edge(style="invis") >> iam
