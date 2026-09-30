# Garage (storage S3)

Nó único, sem replicação. Só o endpoint web (leitura pública) é exposto: `https://media.escapaages.online`.
A API S3 (`garage:3900`) e a admin (`garage:3903`) ficam internas ao cluster.

## Vault (`secret/escapa/garage`)

| Chave | Valor |
|---|---|
| `rpcSecret` | `openssl rand -hex 32` |
| `adminToken` | `openssl rand -base64 32` |

O role `eso-escapa` precisa incluir o namespace `garage` em `bound_service_account_namespaces`.

## Bootstrap (uma vez, depois do primeiro sync)

```sh
G="kubectl -n garage exec garage-0 -- /garage"
$G status                                   # copie o ID do nó
$G layout assign -z dc1 -c 7G <ID_DO_NO>
$G layout apply --version 1
$G bucket create media.escapaages.online    # o nome do bucket é o hostname público
$G bucket website --allow media.escapaages.online
$G key create escapa-admin                  # guarde o secret; ele só aparece agora
$G bucket allow --read --write --owner media.escapaages.online --key escapa-admin
```

CORS (GET/HEAD para o frontend) via API S3, por exemplo com `aws s3api put-bucket-cors`.

## Publicar arquivos

Envie com a chave `escapa-admin` pela API S3 (`kubectl -n garage port-forward svc/garage 3900`,
região `garage`, path-style). Os objetos ficam em `https://media.escapaages.online/<caminho>`.
Certificados: use nomes não adivinháveis (UUID), pois o endpoint web não lista objetos mas serve qualquer chave conhecida.

## DNS

O cloudflared já roteia `*.escapaages.online` para o Traefik. Falta só o CNAME `media` no dashboard da Cloudflare, apontando para o tunnel.
