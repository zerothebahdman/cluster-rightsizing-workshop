# Going further on GKE (stretch section)

This part needs a Google Cloud project **with billing** (the free trial works). The core
workshop doesn't. Delete the cluster when you're done.

## 1. Run the same shop on Autopilot

Autopilot bills for what your **pods request**, not for nodes, so right-sizing shows up
directly on the bill.

```bash
export PROJECT_ID=your-project-id
export REGION=africa-south1   # or the region nearest you
gcloud config set project "$PROJECT_ID"
gcloud services enable container.googleapis.com
gcloud container clusters create-auto rightsizing-demo --region "$REGION"
gcloud container clusters get-credentials rightsizing-demo --region "$REGION"
```

Deploy the bloated shop and the load generator. Autopilot has no "platform" node, so drop
the load generator's node pinning:

```bash
kubectl apply -k app/bloated
kubectl apply -f load/
kubectl -n load patch deploy loadgen --type=json -p='[
  {"op":"remove","path":"/spec/template/spec/nodeSelector"},
  {"op":"remove","path":"/spec/template/spec/tolerations"}]'
```

Compare what you're paying for, before and after:

```bash
kubectl get pods -n shop -o custom-columns='POD:.metadata.name,CPU:.spec.containers[0].resources.requests.cpu,MEM:.spec.containers[0].resources.requests.memory'
kubectl apply -k app/rightsized
kubectl get pods -n shop -o custom-columns='POD:.metadata.name,CPU:.spec.containers[0].resources.requests.cpu,MEM:.spec.containers[0].resources.requests.memory'
```

Autopilot may round very small requests up to its minimums. The
`autopilot.gke.io/resource-adjustment` annotation on a pod shows what it changed:

```bash
kubectl get pod -n shop -l app=cart -o jsonpath='{.items[0].metadata.annotations.autopilot\.gke\.io/resource-adjustment}{"\n"}'
```

## 2. Standard clusters: scale down unused nodes faster

```bash
gcloud container clusters update CLUSTER_NAME --region "$REGION" \
  --autoscaling-profile optimize-utilization
```

`optimize-utilization` makes the cluster autoscaler favour utilization over spare capacity,
removing underused nodes sooner.

## 3. Recommendations and cost visibility

- In the console, open **Kubernetes Engine → Workloads**, pick a deployment, and look for its
  request and limit recommendations (based on VPA).
- Turn on **GKE cost allocation** to break spend down by namespace and label in your Cloud Billing export.

## Clean up

```bash
gcloud container clusters delete rightsizing-demo --region "$REGION" --quiet
```
