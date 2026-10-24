  # Redeploy the API pod alone

Use this after changing anything in `voice-insights-azureapi` (code, `application.properties`) when nothing else changed. The UI, Postgres
and Redis pods are not touched, and the data on the Postgres disk is kept.

```bash
export RG=rg-praveen
export AKS=aks-sgpoc-voice-insights
export NS=nsp-sgpoc-voice-insights
export DOCKERHUB_USER=tpkprav
export TAG=1.0.0            # the tag in kustomization.yaml; use the same one unless you are releasing a new version
```

## 1. Build and push only the API image

Once per terminal: `docker login -u $DOCKERHUB_USER`. Then, from `voice-insights-k8s/`:

```bash
docker buildx build --platform linux/amd64 \
  -t $DOCKERHUB_USER/voice-insights-api:$TAG --push ../voice-insights-azureapi
```

`--platform linux/amd64` matters: AKS nodes are Intel/AMD and your Mac is ARM. (`scripts/push-images.sh` does the same but builds the UI as well.)

## 2. Point kubectl at the cluster

```bash
az aks get-credentials -g $RG -n $AKS --overwrite-existing
kubectl config current-context        # must say aks-sgpoc-voice-insights
```

## 3. Restart the API pod so it pulls the new image

```bash
kubectl -n $NS rollout restart deployment/voice-insights-api
kubectl -n $NS rollout status deployment/voice-insights-api --timeout=300s
```

- Because the tag is reused, `api.yaml` sets `imagePullPolicy: Always`, so the restart pulls the fresh image. (If you ever see the old behaviour
  after a restart, check that line is still there and re-run `kubectl apply -k .`.)
- The Deployment uses the `Recreate` strategy: the old pod stops, then the new one starts. Expect about a minute of downtime while Spring Boot
  starts (up to 3 minutes is allowed by the startup probe). Signed-in users are signed out, because sessions are deleted on API start.
- Do not scale the API above one replica: voice sessions live in the process.

## 4. Check it

```bash
kubectl -n $NS get pods -l app=voice-insights-api            # 1/1 Running, a new AGE
kubectl -n $NS logs deploy/voice-insights-api --tail=50
kubectl -n $NS get deploy voice-insights-api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

To confirm the pod really runs the image you just pushed, compare digests:

```bash
kubectl -n $NS get pod -l app=voice-insights-api -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
docker buildx imagetools inspect $DOCKERHUB_USER/voice-insights-api:$TAG | grep Digest
```

Then open https://aiasg-voice-insights.southeastasia.cloudapp.azure.com and sign in again.

## If you also changed a manifest (`api.yaml`, `configmap.yaml`, `ingress.yaml`)

Apply it first, then restart if the change is only a ConfigMap (pods do not reload a ConfigMap by themselves):

```bash
kubectl apply -k .
kubectl -n $NS rollout restart deployment/voice-insights-api     # only needed for ConfigMap changes
```

## If the new pod does not come up

| Symptom | Fix |
|---|---|
| `ImagePullBackOff` | The push failed or the tag is wrong: `docker buildx imagetools inspect $DOCKERHUB_USER/voice-insights-api:$TAG`. If the repo is private, create the `dockerhub` pull secret (README step 3b). |
| `CrashLoopBackOff` | `kubectl -n $NS logs deploy/voice-insights-api --previous`. A database error usually means the Secret's `POSTGRES_PASSWORD` differs from the one Postgres first started with. |
| Stuck at `0/1 Running` | It is still starting; wait for the startup probe (up to 3 minutes), then check the logs. |
| Roll back | Re-push the previous image under the tag (or use a new tag and set `newTag` in `kustomization.yaml`), then `kubectl -n $NS rollout restart deployment/voice-insights-api`. |

## Knowledge base uploads (up to 700 MB)

Admin -> Knowledge base accepts a zip up to 700 MB. The limits that allow it, and where to change them:

| Where | Setting |
|---|---|
| API | `spring.servlet.multipart.max-file-size` / `max-request-size` in `application.properties` (700MB / 710MB) |
| Ingress | `nginx.ingress.kubernetes.io/proxy-body-size: "750m"` in `ingress.yaml` (apply with `kubectl apply -k .`) |

The API saves the upload to a temporary file in the pod and reads one document at a time, so memory stays low. The temporary file is deleted when
the job ends. A big zip takes a while to embed; the Admin page shows progress, and the job keeps running if you close the tab.
