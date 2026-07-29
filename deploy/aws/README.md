# Deploying the Claude gateway to AWS App Runner

Version-controlled counterpart of the running deployment. The image carries
**code only** — `docker-entrypoint-prod.sh` renders `kong.yaml` at boot from
environment variables, so no vault ID, provider key, or service account is ever
baked in.

## Credential model

| Credential | Held by | Delivered as |
| --- | --- | --- |
| `GATEWAY_API_KEY` | client | `apikey` **or** `x-api-key` header |
| `ANTHROPIC_API_KEY` | gateway | injected by `ai-proxy` as `x-api-key` |
| `OPENAI_AUTH_HEADER` (`Bearer sk-...`) | gateway | injected as `Authorization` |
| `SKYFLOW_SA_JSON` | gateway | signs the vault assertion in-process |

Clients hold exactly one secret. `key-auth` (priority 1250) runs ahead of
`skyflow-deidentify` (775), so an unauthenticated request never reaches Skyflow.

## Routes

| Path | Provider | Notes |
| --- | --- | --- |
| `/claude` | OpenAI | Anthropic protocol in, translated out |
| `/claude-anthropic` | Anthropic | native both ways |
| `/probe/deid` | echo | de-identify only — shows the tokens an upstream sees |
| `/healthz` | — | unauthenticated, for App Runner health checks |

## Build and deploy

```bash
export AWS_REGION=us-east-2 ACCT=<account-id>
aws ecr create-repository --repository-name skyflow-claude-gateway
aws ecr get-login-password | docker login --username AWS --password-stdin $ACCT.dkr.ecr.$AWS_REGION.amazonaws.com

# build context needs the plugin next to these files
cp -r ../../plugin .
docker buildx build --platform linux/amd64 \
  -t $ACCT.dkr.ecr.$AWS_REGION.amazonaws.com/skyflow-claude-gateway:v1 --push .
```

Secrets (one per credential above) go in Secrets Manager under
`skyflow-claude-gateway/*`; the instance role is scoped to that prefix. Create
the service with port **8000** and health check **`/healthz`**, passing
`SKYFLOW_VAULT_ID`, `SKYFLOW_CLUSTER_ID`, `SKYFLOW_ACCOUNT_ID`,
`OPENAI_MODEL`, `ANTHROPIC_MODEL`, `CTX_TENANT` as plain variables and the four
credentials as `RuntimeEnvironmentSecrets`.

Policy changes (models, tenant) are `update-service` only. Rotating a secret
needs `start-deployment`, since values are read at container start.

## Verify

```bash
U=https://<service>.awsapprunner.com
GW=$(aws secretsmanager get-secret-value --secret-id skyflow-claude-gateway/gateway-api-key \
      --query SecretString --output text)

curl -s -o /dev/null -w '%{http_code}\n' $U/healthz                    # 200
curl -s -o /dev/null -w '%{http_code}\n' $U/claude/v1/messages -d '{}'  # 401
curl -s $U/claude-anthropic/v1/messages -H "x-api-key: $GW" \
  -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":80,"messages":[{"role":"user",
       "content":"Greet Jane Doe (jane@acme.com) mentioning her email."}]}' | jq -r '.content[0].text'
```

Note: Kong exposes no `/v1/models`, so clients that offer model discovery
(Claude Desktop) must leave it off and list models explicitly.
