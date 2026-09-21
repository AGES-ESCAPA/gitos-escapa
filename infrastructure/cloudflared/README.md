# Túnel local para os Ingress do cluster

```text
CNAME proxied na Cloudflare -> túnel escapa-ingress -> cloudflared-local
    -> traefik.kube-system.svc.cluster.local:80 -> Ingress -> Service -> Pod
```

`config.yaml` gera um ConfigMap pelo Kustomize. O hash do ConfigMap muda quando
a configuração muda e provoca o rollout do conector na próxima sincronização.
A regra `*.escapaages.online` preserva o Host da requisição para o Traefik escolher
o Ingress. Não configure `httpHostHeader` com um hostname fixo.
Hosts sem Ingress correspondente recebem 404 do Traefik.

O Deployment lê `tunnel-id` e monta `credentials.json` do Secret
`cloudflared-local-credentials`, criado fora do Git. O modo local não usa
`TUNNEL_TOKEN` nem as rotas de Published Applications do painel.

## Configuração

Os comandos são executados pelo administrador. Mantenha a sessão SSH disponível
durante a configuração. A sincronização das Applications de infraestrutura é manual.

1. No computador local, siga a seção de túnel local do README de `terraform-iac`:
   crie `escapa-ingress`, transfira o Secret com o script existente e obtenha
   `terraform output -raw cloudflare_local_tunnel_cname`.
2. Faça commit/push das alterações GitOps, incluindo as remoções pendentes. No clone
   da EC2, execute `git pull --ff-only origin main`.
3. Confira que Traefik existe e que o Secret novo está presente (sem exibir valores):

```bash
sudo k3s kubectl -n kube-system get service traefik
sudo k3s kubectl get ingressclass
sudo k3s kubectl -n cloudflared get secret cloudflared-local-credentials
```

O Service precisa expor a porta 80 e deve existir a classe `traefik`.

## Preparar Argo e Vault

Cadastre/atualize as Applications a partir dos arquivos versionados:

```bash
sudo k3s kubectl apply -f infrastructure/argocd/application.yaml
sudo k3s kubectl apply -f infrastructure/vault/application.yaml
sudo k3s kubectl -n argocd patch application argocd-ingress --type=merge -p '{"operation":{"sync":{"syncOptions":["ServerSideApply=true","DisableClientSideApplyMigration=true"],"syncStrategy":{"hook":{}}}}}'
sudo k3s kubectl -n argocd patch application vault --type=merge -p '{"operation":{"sync":{"syncOptions":["CreateNamespace=true"],"syncStrategy":{"hook":{}}}}}'
sudo k3s kubectl -n argocd get application argocd-ingress vault
```

Espere a sincronização concluir. `argocd-ingress` gerencia apenas o Ingress e os
campos `server.insecure`/`url` dos ConfigMaps; não reinstala o ArgoCD. Confira se
o campo foi aplicado e reinicie somente o servidor Argo para ele reler a opção:

```bash
sudo k3s kubectl -n argocd get configmap argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'
sudo k3s kubectl -n argocd rollout restart deployment/argocd-server
sudo k3s kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
sudo k3s kubectl get ingress -A
```

O campo deve ser `true` antes do restart. A Cloudflare atende o navegador em HTTPS;
o trecho cloudflared -> Traefik -> Argo é HTTP interno. Isso evita o redirecionamento
do Argo para HTTPS em loop. O login do Argo continua obrigatório.
O antigo port-forward SSH do Argo passa a ser acessado com **http://localhost:8080**.
A adição do Ingress do Vault não altera seu StatefulSet ou armazenamento.

Frontend/API têm Ingress em suas pastas de manifests; suas Applications os aplicam
na próxima sincronização. As imagens ainda precisam ser publicadas para os sites responderem.

## Conectar o túnel local

```bash
sudo k3s kubectl -n argocd patch application cloudflared --type=merge -p '{"operation":{"sync":{"syncOptions":["CreateNamespace=true"],"syncStrategy":{"hook":{}}}}}'
sudo k3s kubectl -n cloudflared get deployments,pods
```

Espere aparecer o Deployment `cloudflared-local`, depois confira:

```bash
sudo k3s kubectl -n cloudflared rollout status deployment/cloudflared-local --timeout=180s
sudo k3s kubectl -n cloudflared logs deployment/cloudflared-local --tail=30
```

Espere `Registered tunnel connection`. O Deployment `cloudflared-local` mantém
duas réplicas conectadas ao túnel `escapa-ingress`.

## DNS pelo painel Cloudflare

Em DNS -> Records, crie CNAMEs **Proxied** com TTL Auto:

| Nome | Destino | Ingress |
|---|---|---|
| `argo` | saída de `cloudflare_local_tunnel_cname` | `argocd/argocd-server` |
| `vault` | mesmo destino | `vault/vault` |
| `app` | mesmo destino | `escapa/escapa-frontend` |
| `api` | mesmo destino | `escapa/escapa-backend` |

Comece por `argo` e `vault`; se já existirem registros para esses nomes, edite-os.
Não crie rotas de Published Applications: a configuração local já encaminha os hosts
para o Traefik. Ative **Always Use HTTPS** no domínio para redirecionar acessos HTTP.
Teste `https://argo.escapaages.online` e `https://vault.escapaages.online/ui/`, incluindo
o login. Depois troque o destino dos CNAMEs existentes `app` e `api` quando seus Ingress
estiverem presentes.

O túnel local não exige reiniciar os conectores para novos hosts: basta criar o
Ingress e o CNAME correspondente.

## Limpeza da configuração anterior

A configuração remota foi retirada dos repositórios. Em um cluster existente,
sincronize a Application `cloudflared` com prune após publicar essas alterações para
remover o Deployment antigo `cloudflared`. O Secret antigo `cloudflared-credentials`,
criado fora do GitOps, pode ser excluído manualmente. O Secret usado pelo conector
atual é `cloudflared-local-credentials`.

No Terraform, o próximo plano completo deverá propor a remoção do túnel remoto,
de sua configuração e do segredo aleatório antigo. Revise separadamente qualquer
diferença da EC2; não é necessário modificar a VM para remover o túnel antigo.

Novas aplicações devem manter o Ingress junto aos seus manifests/valores Helm.
O host precisa estar sob `escapaages.online` para corresponder à regra do túnel.
Não é necessário abrir portas adicionais no Security Group da EC2.

Referências: [configuração local do túnel](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/configuration-file/),
[DNS do túnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/)
e [Ingress do ArgoCD](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/).
