# Credenciais do Vault para Kubernetes

O External Secrets Operator (ESO) lê o KV v2 do Vault e cria os Secrets que os
charts/StatefulSets já referenciam. O Vault Agent Injector permanece destinado ao
backend; ele não substitui essa sincronização.

Os arquivos deste repositório contêm referências e permissões, sem senhas ou tokens.
Não salve chaves de unseal, token inicial ou resultados de `vault kv get` no Git.

## 1. Pré-requisitos

Vault inicializado, desbloqueado, KV v2 habilitado em `secret/` e autenticação
Kubernetes habilitada em `auth/kubernetes/`. A configuração deve usar
`kubernetes_host=https://kubernetes.default.svc:443`.
No pod, o Vault usa o token/CA locais para TokenReview. O chart do Vault concede
`system:auth-delegator` ao ServiceAccount do servidor; as identidades abaixo não
precisam dessa permissão.

Publique as alterações em `main`, depois atualize o clone no node. Todos os comandos
abaixo são executados pelo administrador nesse clone, dentro da EC2.

## 2. Instalar o operador

```bash
git pull --ff-only origin main
sudo k3s kubectl apply -f infrastructure/external-secrets/application.yaml
sudo k3s kubectl -n argocd patch application external-secrets --type=merge -p '{"operation":{"sync":{"syncOptions":["CreateNamespace=true","ServerSideApply=true"],"syncStrategy":{"hook":{}}}}}'
sudo k3s kubectl -n external-secrets get pods
```

Aguarde os três Deployments do operador ficarem disponíveis antes de aplicar
SecretStores/ExternalSecrets. Server-side apply evita o limite de tamanho da
anotação de client-side apply nas CRDs.

## 3. Autorizar a leitura no Vault

Se necessário, autentique a CLI dentro do pod com `vault login -no-print`:

```bash
sudo k3s kubectl -n vault exec -it vault-0 -- vault login -no-print
bash scripts/configure-vault-eso.sh
```

O script grava três policies e roles, sem criar/alterar credenciais. Cada role
aceita somente o ServiceAccount `vault-secrets` no namespace correspondente,
com audience `vault`. Cada policy permite ler apenas um caminho de dados.
O operador solicita tokens temporários via TokenRequest, sem um token root em Secret.

## 4. Cadastrar os valores no KV

Cadastre diretamente no Vault os caminhos e campos abaixo, antes de sincronizar
as Applications `vault-secrets-*`. Use valores próprios; não coloque as senhas
em comandos versionados, argumentos do shell ou mensagens de chat.

| Caminho KV (CLI/UI) | Campos | Namespace / Secret Kubernetes |
|---|---|---|
| `secret/escapa/database` | `username`, `password` | `escapa-prod` / `escapa-database-creds` |
| `secret/escapa/minio` | `rootUser`, `rootPassword` | `minio` / `minio-root-credentials` |
| `secret/escapa/grafana` | `admin-user`, `admin-password` | `monitoring` / `grafana-admin-credentials` |

As policies usam `secret/data/...` porque esse é o caminho da API KV v2; o ESO já
adiciona `data/` às referências `escapa/...` dos manifests.
Se houver um banco ou Grafana inicializado, preserve as credenciais existentes:
trocar o Secret não altera automaticamente a senha salva no banco da aplicação.

## 5. Sincronizar uma integração por vez

Comece pelo PostgreSQL, depois repita para `minio` e `grafana`:

```bash
sudo k3s kubectl apply -f infrastructure/vault-secrets/database-application.yaml
sudo k3s kubectl -n argocd patch application vault-secrets-database --type=merge -p '{"operation":{"sync":{"syncOptions":["CreateNamespace=true"],"syncStrategy":{"hook":{}}}}}'
sudo k3s kubectl -n escapa-prod get secretstore,externalsecret
sudo k3s kubectl -n escapa-prod get secret escapa-database-creds
```

Espere `Ready=True` no SecretStore e ExternalSecret antes de iniciar o consumidor.
O último comando mostra apenas metadados, sem revelar os valores. Se o StatefulSet
do banco já existir, ele poderá iniciar assim que o Secret for criado.
Em caso de falha, use `describe externalsecret` ou `describe secretstore` no namespace.

As Applications de integração ficam com sync manual, mas o ESO consulta o Vault a
cada minuto depois da primeira implantação. Os Secrets usam `creationPolicy: Orphan`
e `deletionPolicy: Retain`: remover o ExternalSecret ou a entrada do Vault não remove
automaticamente as credenciais materializadas. A limpeza é uma ação separada.
Atualizar valores no Vault atualiza o Secret, mas não reinicia pods nem executa a
rotação da senha dentro do PostgreSQL/Grafana; coordene essas alterações.

Após cada componente, acompanhe `sudo k3s kubectl top nodes` e `top pods -A`.
O operador acrescenta três pods, com requests de memória somando 128 MiB.
A persistência do Vault permite reutilizar os dados após reiniciar; com Shamir,
será preciso fazer unseal novamente. Guarde as chaves fora do repositório e mantenha
backup do volume: o armazenamento local depende do disco da EC2.

Referências: [ESO com Vault](https://external-secrets.io/latest/provider/hashicorp-vault/)
e [autenticação Kubernetes do Vault](https://developer.hashicorp.com/vault/docs/auth/kubernetes).
