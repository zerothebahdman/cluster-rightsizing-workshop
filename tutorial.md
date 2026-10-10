# Cut Your Cluster in Half

<walkthrough-tutorial-duration duration="90"></walkthrough-tutorial-duration>

A hands-on Kubernetes right-sizing clinic. You'll take a deliberately bloated
five-service shop, measure what it really uses, pack it onto half the nodes, and
add the safety rails that stop dense packing from causing outages.

Everything runs inside this Cloud Shell. No billing, nothing to install.

**Stuck at any point?** `./catchup.sh <lab number>` resets you to the start of that lab.

## Start your cluster

Run the setup script. It takes about 4 minutes, so start it now and listen in while it builds.

```bash
./setup.sh
```

You get a [kind](https://kind.sigs.k8s.io) cluster with:

* **1 control plane**: Kubernetes itself.
* **1 platform node** (`workshop-worker`): DNS, metrics-server, the VPA recommender and a load generator.
* **4 app nodes** (`workshop-worker2` to `workshop-worker5`): each capped at **1 CPU and 1 GiB**, like small cloud VMs.

The shop has five services: `gateway`, `catalog`, `cart`, `checkout` and `worker`.
A load generator drives each pod to a steady, realistic amount of CPU and memory,
so everyone in the room sees the same numbers.

When setup finishes, look at the shop:

```bash
kubectl get pods -n shop -o wide
```

One pod is **Pending**. The cluster is "full", even though nothing is busy yet.
Remember that.

## Lab 1: Measure what you actually use

Give the load generator a couple of minutes to warm up, then compare what each
service *asks for* with what it *uses*:

```bash
kubectl top pods -n shop
```

```bash
./tools/waste-report.sh
```

Things to notice:

* Every service requests **400m CPU and 256Mi**: the same copy-pasted block.
* Real usage is a small fraction of that. Look at the `WASTE` columns.
* The Pending pod has a request but no node, because requests filled every node *on paper*.

Now look at the nodes the way the scheduler does:

```bash
./tools/nodes.sh
```

Every app node is about 90% "full" by requests, and nearly idle in reality.
**The scheduler and the autoscaler only look at requests, never usage.** That's the bill.

## Lab 2: Let VPA recommend

Each service has a VerticalPodAutoscaler in **recommendation-only** mode
(`updateMode: "Off"`). It watches real usage and suggests requests, but never touches a pod.

```bash
kubectl get vpa -n shop
```

```bash
kubectl describe vpa catalog -n shop
```

Under `Recommendation` you'll see:

* **target**: what VPA would set. By default, about the 90th percentile of observed usage plus a 15% safety margin.
* **lowerBound / upperBound**: the range it's confident in. For the first few minutes upperBound is huge, because VPA has very little history yet.

Get every recommendation as a ready-to-run command:

```bash
./tools/vpa-report.sh
```

No numbers yet? VPA needs a few minutes of load. Re-run it in a minute.

## Lab 3: Right-size and give back nodes

Apply the new requests. Pick **one** option:

**Option A: your own VPA numbers** (memory limit = request, no CPU limit):

```bash
./tools/vpa-report.sh --apply
```

**Option B: the reference answer** (see `app/rightsized/kustomization.yaml`):

```bash
kubectl apply -k app/rightsized
```

Watch the pods restart with their new sizes, and the Pending pod finally schedule:

```bash
kubectl get pods -n shop -o wide
```

```bash
./tools/nodes.sh
```

Every node is now mostly empty on paper. Give two of them back:

```bash
kubectl drain workshop-worker4 --ignore-daemonsets --delete-emptydir-data
kubectl drain workshop-worker5 --ignore-daemonsets --delete-emptydir-data
```

```bash
./tools/nodes.sh && kubectl get pods -n shop -o wide
```

**Same 9 pods, 2 app nodes instead of 4.** On a real cloud, those two nodes are money
back every month. Check the waste report again:

```bash
./tools/waste-report.sh
```

## Lab 4: Break it on purpose

Dense packing leaves less slack, so let's see what failure looks like before it happens in production.

**Memory too low.** Give `cart` less memory than it needs:

```bash
kubectl set resources deploy/cart -n shop --requests=memory=24Mi --limits=memory=24Mi
```

```bash
kubectl get pods -n shop -l app=cart -w
```

Within a minute or two it restarts. Press `Ctrl+C`, then ask why:

```bash
kubectl describe pod -n shop -l app=cart | grep -A4 "Last State"
```

`OOMKilled`, exit code 137. Memory can't be throttled, so the kernel kills the container.

**CPU too low.** Cap `worker` well below what it uses:

```bash
kubectl set resources deploy/worker -n shop --requests=cpu=40m --limits=cpu=50m
```

Wait a minute or two, then:

```bash
kubectl top pods -n shop -l app=worker
```

It wants about 150m, but it's stuck near 50m. Nothing crashed: it just got slow.
**Throttling is a quiet failure**, which is why CPU limits deserve caution.

Want proof? Ask the kernel how often it paused the container:

```bash
kubectl exec -n shop deploy/worker -- cat /sys/fs/cgroup/cpu.stat
```

`nr_throttled` out of `nr_periods` is how many 100ms slices it was throttled in. In
rehearsals it was 60–99% of them. `throttled_usec` is the total time it spent waiting.

Reset to the right-sized state before the next lab:

```bash
./catchup.sh 5
```

## Lab 5: Safety rails for dense packing

**1. A disruption budget that's too strict.** Apply a PDB that never allows a checkout pod to be evicted:

```bash
kubectl apply -f rails-demo/strict-pdb.yaml
NODE=$(kubectl get pod -n shop -l app=checkout -o jsonpath='{.items[0].spec.nodeName}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --dry-run=server --timeout=20s
```

You'll see `Cannot evict pod as it would violate the pod's disruption budget`, retried
until the 20-second timeout. `minAvailable` equals the replica count, so that node can
never be drained, and that includes node upgrades. (`--dry-run=server` means nothing was really evicted.) Remove it:

```bash
kubectl delete -f rails-demo/strict-pdb.yaml
```

**2. Now the real rails.** Apply PDBs that allow one replica down at a time,
priority classes, default requests and a namespace budget:

```bash
kubectl apply -k rails
```

```bash
kubectl get pdb,limitrange,resourcequota -n shop && kubectl get priorityclass | grep shop
```

**3. Priority in action.** Scale checkout (critical) far past what fits:

```bash
kubectl scale deploy/checkout -n shop --replicas=12
kubectl get pods -n shop -l 'app in (checkout,worker)' -o wide
```

Some checkout pods don't fit, so the scheduler preempts the lowest-priority pod, a batch `worker`, to make room. When space runs out, critical services win.
Scale back:

```bash
kubectl scale deploy/checkout -n shop --replicas=2
```

**4. Defaults for unsized pods.** Launch a pod with no resources at all:

```bash
kubectl run naked -n shop --image=registry.k8s.io/e2e-test-images/resource-consumer:1.13 --restart=Never
kubectl get pod naked -n shop -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl delete pod naked -n shop
```

The LimitRange filled in requests, so the pod can't sneak in unsized.

**5. A budget for the namespace.** Try to bring the bloat back:

```bash
kubectl scale deploy/gateway -n shop --replicas=30
kubectl get events -n shop --field-selector reason=FailedCreate | tail -3
kubectl scale deploy/gateway -n shop --replicas=2
```

`exceeded quota`: the ResourceQuota stops the namespace growing past its budget.

## Going further on GKE

On GKE these habits turn straight into money:

* **Autopilot** bills for pod *requests*, not nodes. Every millicore you trim comes off the bill.
* **Standard clusters**: the `optimize-utilization` autoscaling profile removes underused nodes faster:
  `gcloud container clusters update CLUSTER --autoscaling-profile optimize-utilization`
* **Built-in recommendations**: the GKE console shows request and limit suggestions per workload.
* **Cost allocation**: see spend by namespace and label in your Cloud Billing export.

The speaker will demo this. See `gke/README.md` if you want to try it on your own project.

## Wrap-up

Take this back to your team:

1. **Measure first**, under real load, before you touch requests.
2. **Request from data**: p90 to p95 usage plus headroom, not copy-paste.
3. **Memory limit = memory request**, so memory failures are fast and loud.
4. **Protect dense nodes** with PDBs and PriorityClasses before you pack tighter.
5. **Enforce defaults** with LimitRange and ResourceQuota.
6. **Re-measure regularly**: usage drifts as your code changes.

Done? Delete the cluster:

```bash
./cleanup.sh
```

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>
