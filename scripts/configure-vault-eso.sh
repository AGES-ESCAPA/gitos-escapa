#!/usr/bin/env bash
# Executar no node, após vault login dentro do pod. Não recebe nem imprime tokens.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for component in database minio grafana; do
  case "$component" in
    database) namespace=escapa-prod ;;
    minio) namespace=minio ;;
    grafana) namespace=monitoring ;;
  esac

  sudo k3s kubectl -n vault exec -i vault-0 -- \
    vault policy write "eso-$component" - \
    < "$repo_dir/infrastructure/vault/policies/eso-$component.hcl"

  sudo k3s kubectl -n vault exec vault-0 -- \
    vault write "auth/kubernetes/role/eso-$component" \
    bound_service_account_names=vault-secrets \
    "bound_service_account_namespaces=$namespace" \
    audience=vault \
    "token_policies=eso-$component" \
    token_ttl=1h \
    token_max_ttl=1h
done
