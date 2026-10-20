# Voice Insights on Azure AKS (POC)

Two app pods (UI and API) plus Postgres/pgvector and Redis as pods, all in one namespace, `voice-insights`.

```
                      Internet (HTTPS)
                            |
               Azure Load Balancer (public IP + DNS name)
                            |
                     ingress-nginx  (+ Let's Encrypt certificate)
                  /api, /ws |        | /
                            v        v
        namespace: voice-insights
        ┌──────────────────────────┐   ┌──────────────────┐
        │ voice-insights-api :8084 │   │ voice-insights-ui │
        └───────┬──────────┬───────┘   └──────────────────┘
                │          │
        ┌───────v───┐  ┌───v─────┐          API ──https/wss──> Azure OpenAI (your existing resource)
        │ postgres  │  │  redis  │
        │ + pgvector│  │ (cache) │
        │ 10Gi disk │  └─────────┘
        └───────────┘
```

Why one hostname with HTTPS: the browser only allows the **microphone** on `https://` (or localhost), and the API only accepts
cross-origin calls from `localhost`. With the UI and API behind the same hostname there is nothing to configure for CORS, and the
UI is built to call "its own host".

Files in this folder

| File | What it is |
|---|---|
| `namespace.yaml`, `configmap.yaml` | Namespace, and the non-secret settings (Azure OpenAI endpoint and deployment names, in-cluster addresses) |
| `secrets.example.yaml` | Template only. The real Secret is created from the command line (step 8) |
| `postgres.yaml` | Postgres 16 + pgvector, one pod, 10Gi Azure disk |
| `redis.yaml` | Redis (session cache, no disk) |
| `api.yaml`, `ui.yaml` | The two application Deployments and Services |
| `ingress.yaml`, `cluster-issuer.yaml` | Public HTTPS entry and the Let's Encrypt issuer |
| `kustomization.yaml` | Applies everything and sets your Docker Hub image names |
| `scripts/push-images.sh` | Builds both images for AKS and pushes them to Docker Hub |

---

## 0. What you need on your laptop

`az` (Azure CLI), `kubectl`, `helm`, `docker` (with buildx). All are already installed on this Mac.

Pick values once and reuse them in the commands below (change them if you like):

```bash
export RG=rg-voice-insights
export LOCATION=southeastasia            # close to Singapore users; use the region your subscription allows
export AKS=aks-voice-insights
export DNS_LABEL=voice-insights-<something-unique>     # becomes <label>.<region>.cloudapp.azure.com
export DOCKERHUB_USER=tpkprav
export TAG=1.0.0
```

## 1. Log in to Azure

```bash
az login
az account list -o table                       # find the subscription you want to pay with
az account set --subscription "<name or id>"
```

## 2. Create the AKS cluster

```bash
az group create --name $RG --location $LOCATION

az aks create \
  --resource-group $RG --name $AKS \
  --node-count 2 --node-vm-size Standard_D4s_v5 \
  --enable-managed-identity --generate-ssh-keys \
  --tier free
```

Two `Standard_D4s_v5` nodes (4 vCPU, 16 GB each, Intel/AMD) leave plenty of headroom, so nothing waits for CPU or memory during the demo.
The pods reserve about 2 vCPU and 4 GB in total and may burst higher (see the sizing note at the end). If your subscription has no quota for
that size, use `Standard_D2s_v5` and expect less headroom. This takes about 5 to 10 minutes.

**For speed, create the cluster in the same Azure region as your Azure OpenAI resource** (`aia-voice-insight`; see its Overview page in the
Azure portal). Every voice turn and every analysis is a call to Azure OpenAI, so distance to it is the biggest source of lag. Set `LOCATION`
to that region before `az group create`.

Connect `kubectl` to the new cluster. **Important:** your `kubectl` currently points at an older cluster
(`apim-msi-aks-demo…`) that no longer resolves. This command switches it, so you never apply to the wrong place.

```bash
az aks get-credentials --resource-group $RG --name $AKS --overwrite-existing
kubectl config current-context                 # must say $AKS
kubectl get nodes                              # 2 nodes, STATUS Ready
```

## 3. Push the images to Docker Hub

In **your own terminal** (it asks for a password, so I cannot do it for you; in Claude Code type `! docker login -u $DOCKERHUB_USER`):

```bash
docker login -u $DOCKERHUB_USER                # use a Docker Hub access token as the password (hub.docker.com > Account settings > Security)
./scripts/push-images.sh $DOCKERHUB_USER $TAG
```

This builds for `linux/amd64` (AKS nodes are Intel/AMD, your Mac is ARM) and pushes
`$DOCKERHUB_USER/voice-insights-api:$TAG` and `$DOCKERHUB_USER/voice-insights-ui:$TAG`.

**Mac (ARM) vs Azure (Intel/AMD):** the script builds `linux/amd64`, which is what the AKS nodes run, so the Mac does not matter.
Both images are already pushed as `linux/amd64`. Alpine is not a problem either: the API already runs on Alpine locally.

**3b. Not needed at the moment.** Both repositories (`tpkprav/voice-insights-api`, `tpkprav/voice-insights-ui`) are public, so AKS pulls them
with no credentials. Only if you later make one private, create a pull secret and enable it:

```bash
kubectl apply -f namespace.yaml
kubectl -n voice-insights create secret docker-registry dockerhub \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=$DOCKERHUB_USER --docker-password='<docker hub access token>'
```

then remove the `#` in front of the two `imagePullSecrets:` / `- name: dockerhub` lines in `api.yaml` (and `ui.yaml` if it is private too).
No secrets are baked into either image: the API key and database password are only supplied at run time (step 8).

## 4. Install the ingress controller (the public front door)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$DNS_LABEL

kubectl -n ingress-nginx get svc ingress-nginx-controller -w     # wait until EXTERNAL-IP shows an address, then Ctrl+C
```

Your site's address is now `$DNS_LABEL.$LOCATION.cloudapp.azure.com`. Check it resolves:
`nslookup $DNS_LABEL.$LOCATION.cloudapp.azure.com`. (If the label is taken in that region, the install fails with a clear message. Pick
another label and `helm upgrade` with the new value.)

## 5. Install cert-manager (free HTTPS certificate)

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true

kubectl -n cert-manager get pods               # wait until all 3 are Running
```

Edit `cluster-issuer.yaml`, put your real email on the `email:` line, then:

```bash
kubectl apply -f cluster-issuer.yaml
```

## 6. Edit the manifests (two small edits)

```bash
HOST=$DNS_LABEL.$LOCATION.cloudapp.azure.com
sed -i '' "s/YOUR-DNS-LABEL.REGION.cloudapp.azure.com/$HOST/g" ingress.yaml      # macOS sed; on Linux drop the ''
# kustomization.yaml already points at tpkprav/voice-insights-api and -ui, tag 1.0.0; change newTag only when you push a new version.
```

Optional but recommended for a POC: in `ingress.yaml`, remove the `#` on the `whitelist-source-range` line and put your office/home
public IP there. Without it, **anyone on the internet can open the site, sign up, and spend your Azure OpenAI quota.**

## 7. Create the namespace

```bash
kubectl apply -f namespace.yaml
```

## 8. Create the secrets

Never put these in a file you commit. Use a strong database password (it is only reachable from inside the cluster).

```bash
kubectl -n voice-insights create secret generic voice-insights-secrets \
  --from-literal=POSTGRES_PASSWORD='<choose a password>' \
  --from-literal=AZURE_OPENAI_API_KEY='<your Azure OpenAI key, from voice-insights-azureapi/.env>'
```

## 9. Deploy

```bash
kubectl apply -k .
kubectl -n voice-insights get pods -w
```

You should end up with `postgres-0`, `redis-…`, `voice-insights-api-…` and `voice-insights-ui-…` all `Running` and `1/1` Ready.
The API pod waits for Postgres and Redis, then needs up to about a minute to start. Useful checks:

```bash
kubectl -n voice-insights logs deploy/voice-insights-api --tail=50
kubectl -n voice-insights get ingress
kubectl -n voice-insights get certificate        # READY True once Let's Encrypt has issued it (1-3 minutes)
```

## 10. Load the product documents (so suggestions have something to search)

A new database is empty. Simplest: open the site, sign up, go to **Admin > Knowledge base**, and upload
`../voice-insights-ingestor/src/main/resources/input.zip` (the two AIA products). Or copy what you already have locally:

```bash
# on your Mac (local Docker Postgres):
docker exec voice_insights_postgres pg_dump -U admin -d ingestor --data-only -t voice_insights.product_chunks > /tmp/product_chunks.sql
# after the API has started once (it creates the table on first boot):
kubectl -n voice-insights exec -i postgres-0 -- psql -U admin -d ingestor < /tmp/product_chunks.sql
```

## 11. Open it

`https://<DNS_LABEL>.<LOCATION>.cloudapp.azure.com` → **Sign up** (create your first account) → try a debrief. The browser will ask for
microphone permission; that only works because the site is on HTTPS.

---

## Day-two commands

```bash
# Logs
kubectl -n voice-insights logs deploy/voice-insights-api -f
# A new version: push a new tag, then
kustomize edit set image voice-insights-api=$DOCKERHUB_USER/voice-insights-api:1.0.1     # or edit kustomization.yaml
kubectl apply -k .
# Restart something
kubectl -n voice-insights rollout restart deploy/voice-insights-api
# Look inside the database
kubectl -n voice-insights exec -it postgres-0 -- psql -U admin -d ingestor
# Back it up
kubectl -n voice-insights exec postgres-0 -- pg_dump -U admin -d ingestor -n voice_insights > backup.sql
# Pause the cluster to save money (nodes stop billing; the disk and data are kept)
az aks stop --resource-group $RG --name $AKS        # later: az aks start ...
# Remove everything
az group delete --name $RG --yes --no-wait
```

Sizing (why the demo should not lag)

| Pod | Reserved | May use | Notes |
|---|---|---|---|
| voice-insights-api | 1 CPU, 2 GiB | 3 CPU, 3 GiB | The busy one. The JVM heap is sized from this limit and starts at 50%, so it does not stop to grow mid-demo. |
| postgres | 0.5 CPU, 1.5 GiB | 2 CPU, 2.5 GiB | Premium SSD disk, larger buffer cache. |
| voice-insights-ui | 0.1 CPU, 64 MiB | 0.5 CPU, 256 MiB | Static files; tiny. |
| redis | 0.1 CPU, 128 MiB | 0.5 CPU, 256 MiB | Session cache only. |

Before the CEO demo: keep the cluster running (do not `az aks stop` the day before: the API takes about a minute to start), run one full
debrief a few minutes earlier so the first real one is not the first the server has ever handled, and use a wired or strong connection (the
microphone streams audio all the time).

Things to know
- **Restarting the API signs everyone out** (sessions are cleared on boot by design). Postgres data, including accounts and runs, survives.
- **Keep the API at one replica.** Live voice sessions and analysis state live in the process. Scale the nodes, not this deployment.
- **Postgres is one pod on one disk.** Fine for a POC; take backups (above) before deleting anything. Deleting the namespace deletes the disk.
- **Cost:** 2 × D2s_v5 nodes + a disk + a public IP is roughly the price of two small VMs. `az aks stop` between demos.

## If something is wrong

| You see | Likely cause and fix |
|---|---|
| `ImagePullBackOff` | Wrong Docker Hub user/tag in `kustomization.yaml`, or the repo is private (do step 3b). `kubectl -n voice-insights describe pod <pod>` shows the message. |
| API pod `CrashLoopBackOff`, log says it cannot connect to the database | The Secret's `POSTGRES_PASSWORD` differs from what Postgres first started with. Delete the disk and start clean: `kubectl -n voice-insights delete sts postgres && kubectl -n voice-insights delete pvc data-postgres-0`, then `kubectl apply -k .` |
| API log: `AZURE_OPENAI_API_KEY` / 401 from Azure | Wrong key in the Secret. Fix it with `kubectl -n voice-insights create secret generic voice-insights-secrets ... --dry-run=client -o yaml | kubectl apply -f -`, then restart the API. |
| Site opens but the browser says "Not secure" | The certificate is not ready yet: `kubectl -n voice-insights describe certificate voice-insights-tls`. The DNS name must resolve to the ingress IP first (step 4). |
| Microphone does nothing | The page is on `http://`, not `https://`. Use the https address. |
| Every call fails with 403 "Invalid CORS request" | The API is not trusting the ingress's forwarded headers. `SERVER_FORWARD_HEADERS_STRATEGY: framework` must be in `configmap.yaml`; after fixing run `kubectl apply -k .` and restart the API. |
| "502 Bad Gateway" | The API pod is still starting (wait a minute) or not Ready: `kubectl -n voice-insights get pods`. |
| Voice stops after a while / analysis stream cuts out | Check the ingress kept its timeout annotations (`kubectl -n voice-insights get ingress voice-insights -o yaml`). |
| `kubectl` talks to the wrong cluster | `kubectl config get-contexts`, then `az aks get-credentials ... --overwrite-existing` (step 2). |
