# Cut Your Cluster in Half

**A hands-on Kubernetes right-sizing clinic.** DevFest 2026 workshop by Divinewill (ZERO) Okoro.

Take a deliberately bloated five-service app, measure what it actually uses, right-size it
onto half the nodes, and add the safety rails that keep dense packing from causing outages.

Runs entirely in **Google Cloud Shell**: free, no credit card, nothing to install.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/zerothebahdman/cut-your-cluster&cloudshell_tutorial=tutorial.md&show=terminal)

## Start

1. Click **Open in Cloud Shell** above and sign in with any Google account.
2. The step-by-step tutorial opens beside the terminal. Run `./setup.sh` and follow along.

Prefer to do it by hand? In any Cloud Shell:

```bash
git clone https://github.com/zerothebahdman/cut-your-cluster
cd cut-your-cluster
./setup.sh
```

Then follow [tutorial.md](tutorial.md).

## The labs

| Lab | What you do | Key tool |
|---|---|---|
| 1. Measure | Compare requests with real usage under load | `./tools/waste-report.sh` |
| 2. Recommend | Read VPA's recommendations | `./tools/vpa-report.sh` |
| 3. Right-size | Apply new requests and drain 2 of 4 nodes | `./tools/nodes.sh` |
| 4. Break it | Trigger an OOMKill and CPU throttling on purpose | `kubectl top`, `describe` |
| 5. Safety rails | PDBs, PriorityClasses, LimitRange, ResourceQuota | `kubectl apply -k rails` |

Stuck? `./catchup.sh <lab>` resets you to the start of any lab. Done? `./cleanup.sh`.

## What's in the repo

```
setup.sh            builds the kind cluster and deploys the bloated shop (safe to re-run)
catchup.sh <1-5>    jump to the start of any lab
cleanup.sh          delete the cluster
app/base/           the five services, headless Services, VPAs (recommendation-only)
app/bloated/        "before": the same copy-pasted 400m / 256Mi everywhere
app/rightsized/     "after": the reference right-sized requests
load/               load generator that drives each pod to a fixed CPU/memory profile
rails/              Lab 5 safety rails, layered on the right-sized shop
rails-demo/         a deliberately too-strict PodDisruptionBudget
tools/              waste report, VPA report, node fill view
tests/              unit tests, lint, and a full end-to-end rehearsal
gke/                notes for the GKE stretch section
```

### How the cluster fakes "small nodes"

kind runs every node as a container on one VM, so every node would normally report the whole
VM's capacity. `setup.sh` reserves almost all of it through the kubelet's `systemReserved`,
leaving each node with **1 CPU and 1 GiB allocatable**. That makes the scheduler behave as
if it were packing small cloud VMs, which is what makes "4 nodes → 2 nodes" real.

### Why the app uses `resource-consumer`

Each service runs Kubernetes' own `resource-consumer` test image. The load generator asks
every pod to burn a fixed amount of CPU and hold a fixed amount of memory, so usage is
realistic but identical for everyone in the room.

## Testing

```bash
./tests/unit.sh   # quantity parsing and the waste table, no cluster needed
./tests/lint.sh   # shellcheck + every kustomization builds
./tests/e2e.sh    # full rehearsal in Cloud Shell (~20 min), writes ~/e2e-report.txt
```
