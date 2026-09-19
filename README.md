# gitops-escapa

Repositório GitOps para a Plataforma de Educação Continuada ESCAPA.

## Padrão adotado: App of Apps (ArgoCD)

```
gitops-escapa/
├── bootstrap/                     # Aplicados manualmente 1x (kubectl apply -f bootstrap/)
│   ├── infrastructure-root.yaml   # App-of-apps -> infrastructure/
│   └── apps-root.yaml             # App-of-apps -> apps/
├── infrastructure/                # Stack base do cluster (1 Application ArgoCD por ferramenta, via Helm)
│   ├── argocd/                    # self-management do próprio ArgoCD (opcional)
│   ├── prometheus/                # métricas (kube-prometheus-stack)
│   ├── loki/                      # logs (loki + promtail)
│   ├── vault/                     # segredos (senhas de banco, chaves de API) - modo standalone
│   └── minio/                     # storage S3-compatible (materiais de curso, certificados, backups)
└── apps/
    └── escapa/                    # App-of-apps da aplicação
        ├── frontend/base + overlays/{dev,prod}
        ├── backend/base  + overlays/{dev,prod}
        └── database/base + overlays/{dev,prod}
```

## Fluxo de bootstrap

1. Instalar o ArgoCD manualmente no cluster (única etapa não-GitOps, "ovo e a galinha"):
   ```
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```
2. Aplicar os dois App-of-Apps raiz:
   ```
   kubectl apply -f bootstrap/infrastructure-root.yaml
   kubectl apply -f bootstrap/apps-root.yaml
   ```
3. A partir daí, as Applications com `syncPolicy: automated` são sincronizadas automaticamente
   pelo ArgoCD. `cloudflared` está temporariamente em sincronização manual durante a correção do túnel.
   Qualquer mudança futura é feita via commit neste repositório — nunca via `kubectl apply` direto no cluster.

## Storage: por que local-path e não Longhorn

O cluster é **k3s single-node**. Longhorn replica volumes entre nós para tolerância a falha — com um
node só, as réplicas cairiam no mesmo disco, então você paga o overhead de CPU/RAM dos pods de
engine/replica/instance-manager sem nenhum ganho real de resiliência.

Por isso todo PVC (Prometheus, Loki, Vault, Minio, banco de dados) usa a StorageClass **`local-path`**,
que já vem embutida no k3s (via `local-path-provisioner`), sem dependências extras. Limitações a ter em
mente: só `ReadWriteOnce` e o volume fica preso ao node em que o pod primeiro rodou — irrelevante aqui,
já que só existe um node.

> Se no futuro o cluster crescer para múltiplos nodes, é só reintroduzir o Longhorn como uma
> `Application` de infraestrutura e trocar `storageClassName`/`storageClass` de `local-path` para
> `longhorn` nos manifests — a estrutura do repositório não muda.

Pela mesma lógica, o **Vault** está em modo `standalone` (não HA/Raft com 3 réplicas): num node só, 3
réplicas só triplicariam o consumo de recursos sem tolerância a falha adicional.

## Papel de cada componente

| Componente | Função | Namespace |
|---|---|---|
| **ArgoCD** | Motor de GitOps: sincroniza o estado do cluster com este repo | argocd |
| **Prometheus** (kube-prometheus-stack) | Métricas de cluster e aplicação + Grafana + Alertmanager | monitoring |
| **Loki** | Agregação de logs (via Promtail/Grafana Agent) | monitoring |
| **Vault** (standalone) | Gestão de segredos (credenciais do banco, chaves JWT, etc.) | vault |
| **cloudflared** | Túnel outbound-only da Cloudflare — expõe frontend/backend publicamente sem abrir porta na AWS | cloudflared |
| **Minio** | Storage S3-compatible (vídeos/materiais de curso, certificados PDF, backups) | minio |
| **Escapa Frontend** | Web app (catálogo de cursos, área do aluno) | escapa-{dev,prod} |
| **Escapa Backend** | API (cursos, progresso, certificados, admin) | escapa-{dev,prod} |
| **Escapa Database** | Persistência (Postgres, StatefulSet + PVC local-path) | escapa-{dev,prod} |

## Ambientes

Dois overlays por componente da aplicação: `dev` e `prod`, diferenciando namespace, réplicas, tag de imagem
e limites de recursos. A infraestrutura (Prometheus/Loki/Vault/Minio) roda uma vez só, compartilhada
pelo cluster.

## Segredos que NÃO vêm deste repositório

Dois secrets são pré-requisito para os pods subirem e são criados fora do Git, pelo Terraform
(`terraform-aws-k3s`, via `user_data`) no primeiro boot do node — nunca commitados aqui:

- `ghcr-pull-secret` (namespace `escapa-prod`) — credencial para puxar as imagens privadas do GHCR.
- `cloudflared-credentials` (namespace `cloudflared`) — chave `token` com o token do túnel
  gerenciado remotamente (`config_src = "cloudflare"` no Terraform). O Deployment lê
  essa chave como `TUNNEL_TOKEN`; não usa `credentials.json` nem ConfigMap de rotas.

As rotas `app`/`api` são mantidas pelo Terraform na Cloudflare. Em clusters criados com
o bootstrap antigo, atualize o Secret antes de sincronizar `cloudflared`; o procedimento
está no README do Terraform. Publique as alterações deste repositório antes
da sincronização: o ArgoCD lê `main` no GitHub, não os arquivos do seu computador.
Quando `/ready` responder, os pods estarão conectados à Cloudflare; os sites ainda
dependem dos Services e aplicações de frontend/backend.

Se você recriar esses namespaces manualmente (fora do fluxo Terraform), precisa recriar os secrets
também, ou os pods do backend/frontend/cloudflared ficam em `ImagePullBackOff`/`CrashLoopBackOff`.

## Próximos passos sugeridos (fora deste primeiro corte)

- Ingress controller + cert-manager para TLS automático dos hosts (não incluído ainda).
- Integração Vault -> Kubernetes via **External Secrets Operator** ou **Vault Agent Injector**, para os
  Deployments do backend/database puxarem credenciais do Vault em vez de Secrets estáticos.
- Configurar Loki para usar o Minio como backend de armazenamento dos chunks (`storage_config.aws` apontando
  pro Minio via S3 API) — assim os logs também usam o storage próprio do cluster.
- Como `local-path` não tem snapshot nativo (ao contrário do Longhorn), configurar um `CronJob` de
  backup (ex: `pg_dump` do Postgres) enviando o dump periodicamente pro bucket do Minio.
