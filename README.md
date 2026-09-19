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
│   ├── external-secrets/          # operador que sincroniza credenciais do Vault
│   ├── vault-secrets/             # integrações PostgreSQL, MinIO e Grafana
│   └── minio/                     # storage S3-compatible (materiais de curso, certificados, backups)
└── apps/
    └── escapa/                    # App-of-apps da aplicação
        ├── frontend/base + overlays/{dev,prod}
        ├── backend/base  + overlays/{dev,prod}
        └── database/base + overlays/{dev,prod}
```

## Fluxo de bootstrap

### Primeira implantação na t4g.medium

O perfil de testes inclui banco, MinIO, Vault, cloudflared, Prometheus/Grafana/Alertmanager
e Loki/Promtail. Todas as Applications de infraestrutura ficam cadastradas pela raiz,
com sincronização manual para iniciar cada componente e medir o consumo. Frontend e
backend têm uma réplica em `prod`; suas imagens ainda precisam estar prontas antes
de aplicar `apps-root`.

| Componente | Memória solicitada | Limite de memória | PVC em prod |
|---|---:|---:|---:|
| PostgreSQL | 256 MiB | 512 MiB | 5 GiB |
| MinIO standalone | 512 MiB | 768 MiB | 10 GiB |
| Vault server | 128 MiB | 256 MiB | 1 GiB |
| Vault injector | 64 MiB | 128 MiB | — |
| External Secrets (3 pods) | 128 MiB | 512 MiB | — |
| Prometheus | 256 MiB | 512 MiB | 3 GiB |
| Grafana | 128 MiB | 256 MiB | 1 GiB |
| Alertmanager | 32 MiB | 64 MiB | — |
| Loki | 128 MiB | 256 MiB | 3 GiB |
| Promtail | 64 MiB | 128 MiB | — |

Esse é um ponto de partida para testes com pouca carga, não uma garantia de capacidade.
Os limites somados podem exceder os 4 GiB do node: eles não são uma reserva global e
não evitam pressão de memória se vários componentes crescerem ao mesmo tempo. A tabela
também não inclui k3s, ArgoCD, cloudflared, frontend/backend, operator, exporters,
sidecars e Jobs, que têm consumo adicional. Meça novamente após cada etapa; reduza a
carga ou pause um componente se surgirem OOMKilled, Pending ou pressão de memória.

Prometheus coleta a cada 60 segundos e retém até 24 horas ou 1 GB de blocos, o que
atingir primeiro (WAL e dados recentes também ocupam disco). Loki usa retenção de
24 horas pelo compactor, ingestão limitada e menor paralelismo de consultas.
Os monitores de etcd/scheduler/controller-manager/kube-proxy ficam desativados porque
o k3s não os expõe como o Kubernetes padrão. Prometheus usa server-side apply para as CRDs.
Alertmanager mantém o receiver padrão sem notificações externas.

Os PVCs listados somam 23 GiB. `local-path` não impõe cotas de capacidade: os dados,
imagens e logs compartilham o disco do node. Monitore `df -h /` e mantenha espaço livre.
A estratégia `Recreate` do MinIO evita dois servidores usando o mesmo PVC na atualização,
com uma breve indisponibilidade nesse período.

As credenciais de PostgreSQL, MinIO e Grafana terão o Vault como origem. Os consumidores
já referenciam Secrets Kubernetes. A instalação do External Secrets Operator e as três
integrações estão versionadas, com sincronização manual. Siga o
[procedimento de integração com Vault](docs/vault-secrets.md) após inicializar o Vault.
`secret.yaml.example` documenta o formato do banco e não integra sua renderização.

No node, dentro do clone atualizado deste repositório, aplique a raiz de infraestrutura.
Ela cadastra as ferramentas e integrações de Secrets e gerencia a Application do cloudflared existente:

```bash
sudo k3s kubectl apply -f bootstrap/infrastructure-root.yaml
```

As Applications filhas novas ficam OutOfSync até solicitar a sincronização.
Comece apenas pelo Vault, que não depende das credenciais das outras aplicações:

```bash
sudo k3s kubectl -n argocd wait --for=create application/vault --timeout=120s
sudo k3s kubectl -n argocd patch application vault --type=merge -p '{"operation":{"sync":{"syncOptions":["CreateNamespace=true"],"syncStrategy":{"hook":{}}}}}'
sudo k3s kubectl -n vault get pods,pvc
```

Omitir `revision` da operação usa a versão fixada
em `spec.source.targetRevision`. Não use
`main` como revision de chart Helm. Habilitar sincronização automática é uma alteração
posterior nos manifests, após validar a stack.

Ao criar `operation` diretamente com `kubectl`, inclua as opções da Application em
`operation.sync.syncOptions`: elas não são copiadas automaticamente pelo patch.
Para Vault, MinIO, Loki e `vault-secrets-*` use `CreateNamespace=true`. Para Prometheus
e External Secrets inclua também
`ServerSideApply=true`, necessário para aplicar suas CRDs grandes.

Vault inicia **selado e não inicializado**. Sua inicialização, guarda das chaves de
unseal e configuração de autenticação Kubernetes/policies são etapas posteriores.
Guarde as chaves de unseal e o token inicial fora do Git e fora do próprio Vault.
Configure o KV, policies e a sincronização de Secrets antes de iniciar PostgreSQL,
MinIO e Grafana. O Injector do Vault injeta arquivos em pods; ele sozinho não cria
os Secrets Kubernetes referenciados por esses três componentes.
Não habilite o backend antes de preparar sua integração com Vault.

Depois que os Secrets existirem, aplique `apps/escapa/database-app.yaml` para subir o
banco e sincronize MinIO, Prometheus e Loki por etapa, conferindo `kubectl top` entre elas.
Se já existirem credenciais de um banco inicializado, preserve seus valores ao migrar
para o Vault; alterar apenas o Secret não troca a senha armazenada no PostgreSQL.

### Fluxo geral

1. Instalar o ArgoCD manualmente no cluster (única etapa não-GitOps, "ovo e a galinha"):
   ```
   kubectl create namespace argocd
   kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```
2. Aplicar os dois App-of-Apps raiz:
   ```
   kubectl apply -f bootstrap/infrastructure-root.yaml
   kubectl apply -f bootstrap/apps-root.yaml
   ```
3. A partir daí, as Applications com `syncPolicy: automated` são sincronizadas automaticamente
   pelo ArgoCD. As Applications filhas de infraestrutura ficam em modo manual no perfil de testes.
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

Os secrets abaixo são pré-requisitos para os pods subirem e são criados fora do Git, pelo Terraform
(`terraform-aws-k3s`, via `user_data`) no primeiro boot do node — nunca commitados aqui:

- `ghcr-pull-secret` (namespace `escapa-prod`) — credencial para puxar as imagens privadas do GHCR.
- `cloudflared-credentials` (namespace `cloudflared`) — chave `token` com o token do túnel
  gerenciado remotamente (`config_src = "cloudflare"` no Terraform). O Deployment lê
  essa chave como `TUNNEL_TOKEN`; não usa `credentials.json` nem ConfigMap de rotas.

Outros três terão origem no Vault e serão materializados por External Secrets Operator
([instalação e configuração](docs/vault-secrets.md)):

- `escapa-database-creds` (`escapa-prod`): chaves `username` e `password`.
- `minio-root-credentials` (`minio`): chaves `rootUser` e `rootPassword`.
- `grafana-admin-credentials` (`monitoring`): chaves `admin-user` e `admin-password`.

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
- Configurar o Vault Agent Injector do backend, com policy e role próprias.
- Configurar Loki para usar o Minio como backend de armazenamento dos chunks (`storage_config.aws` apontando
  pro Minio via S3 API) — assim os logs também usam o storage próprio do cluster.
- Como `local-path` não tem snapshot nativo (ao contrário do Longhorn), configurar um `CronJob` de
  backup (ex: `pg_dump` do Postgres) enviando o dump periodicamente pro bucket do Minio.
