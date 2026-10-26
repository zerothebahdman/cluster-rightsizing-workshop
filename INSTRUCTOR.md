# Instructor notes

Run-of-show, pre-event checklist and failure playbook. The DevFest Abuja 2026 slot is a **25-minute talk with a live demo**; the 90-minute hands-on version is kept below for longer slots.

## Pre-event checklist

**One week before**
- [ ] In a fresh Cloud Shell (Restart first), run `./tests/e2e.sh`. Every check should PASS.
- [ ] If "reference sizes survive ... with no restarts" fails, raise the memory in
      `app/rightsized/kustomization.yaml` for the restarting service, using the waste report
      in `~/e2e-report.txt`, and re-run.
- [ ] Update the slide 13 table with the real numbers from the e2e report's Lab 1 waste report.
- [ ] Check `kubectl version`: Cloud Shell's kubectl (1.35 at last check) is outside the supported skew for a 1.37
      cluster. It worked in the spikes, but if anything odd shows up, pin the node image to a version within one minor of kubectl.
- [ ] In a restarted Cloud Shell, run `./tests/registry-check.sh`. The ghcr.io node image should pull in
      well under a minute (20s on 2026-10-10, vs 4-11 min through Docker Hub's mirror). If you change
      the node image version, update the workflow, re-run it (`gh workflow run mirror-node-image.yml`),
      and update `NODE_IMAGE` in `lib/common.sh`.
- [ ] GKE demo: activate the GCP free trial on your own account, run through `gke/README.md` once, then delete the cluster.

**The day before**
- [ ] Repo is public; the README's **Open in Cloud Shell** link works from an incognito window.
- [ ] Repo link and QR code are on slide 6.
- [ ] Ask the organizers to tell attendees: bring a laptop, sign in to a Google account before the session.

**On the day**
- [ ] Arrive early. In your own Cloud Shell, run `./setup.sh`, so a working cluster is ready to project.
- [ ] Have the `gke/` demo cluster created (it takes ~5 minutes) if you're doing the live GKE demo.
- [ ] Open the slides, the tutorial and a terminal side by side.

## Run of show: 25-minute talk (DevFest Abuja 2026)

You drive the demo; attendees watch and run the labs later from the repo. In the Google Slides deck,
slides 5, 6, 7, 10, 11, 18, 19 and 21 are skipped (hidden in presentation mode, kept for the long version).

- **30 minutes before:** `./setup.sh` in your own Cloud Shell, so load and VPA history build up.
  If you rehearsed on it, `./catchup.sh 1` resets to the bloated state and keeps VPA history.

| Time | Slides | What happens |
|---|---|---|
| 0–1:45 | 1–2 | Welcome, who you are |
| 1:45–4:30 | 3–4 | 13% / 20% utilization; the bill is set by guessed requests |
| 4:30–8 | 8–9 | Request, limit, usage; the scheduler packs requests, not usage |
| 8–9 | 12 | The method, then switch to the terminal |
| 9–11 | 13 | Demo: waste report (83%) and node view |
| 11–12:30 | 14 | Demo: `./tools/vpa-report.sh` |
| 12:30–15:30 | 15 | Demo: apply `app/rightsized`, drain worker4 and worker5: 4 → 2 nodes |
| 15:30–17:30 | 16 | Demo: cart OOMKilled at 24Mi; explain throttling verbally |
| 17:30–19:30 | 17 | Demo: re-apply `app/rightsized`, strict PDB blocks a dry-run drain; name the other rails |
| 19:30–21:30 | 20 | Takeaways, including the GKE Autopilot line |
| 21:30–25 | 22 | Thank you, QR codes (repo and LinkedIn), Q&A |

## Run of show: 90-minute hands-on workshop

| Time | Slides | What happens |
|---|---|---|
| 0–2 | 1–2 | Welcome. Ask everyone to open Cloud Shell. |
| 2–5 | 5–6 | Agenda. Everyone starts `./setup.sh`; it builds while you talk. |
| 5–10 | 3–4, 7–10 | Why requests set the bill, scheduler packing, QoS. |
| 10–25 | 11–13 | Lab 1: waste report and node view. Ask for the worst offender. |
| 25–35 | 14 | Lab 2: VPA. Explain p90 + margin and why upperBound is huge at first. |
| 35–50 | 15 | Lab 3: right-size and drain. Celebrate "4 → 2". |
| 50–57 | 16 | Lab 4: OOMKill and throttling. End with `./catchup.sh 5`. |
| 57–72 | 17 | Lab 5: strict PDB, then the real rails, then priority/LimitRange/quota. |
| 72–85 | 18–19 | GKE demo (stretch). Fast finishers follow `gke/README.md`. |
| 85–90 | 20–22 | Takeaways, Q&A. |

## Failure playbook

| Symptom | Fix |
|---|---|
| `setup.sh` fails creating the cluster | `./cleanup.sh && ./setup.sh` |
| Cloud Shell disconnected | Reconnect, `cd cluster-rightsizing-workshop`, `./setup.sh`. It re-uses the cluster and keeps the attendee's lab state. |
| Cloud Shell VM was recycled (cluster gone) | `./catchup.sh <lab>`: it runs setup first, ~4 min |
| `waste-report.sh`: "No metrics yet" | metrics-server needs ~1 minute after setup; retry |
| `vpa-report.sh` shows "no data yet" | VPA needs a few minutes of load; carry on with Lab 1 and come back |
| Someone is lost | `./catchup.sh <lab>` and point at slide 21 |
| Cloud Shell itself is down or blocked | Project your own cluster and let people pair up |

## How the numbers are designed

- App nodes: 1 CPU / 1 GiB allocatable each (kindnet takes 100m / 50Mi of that).
- Bloated: 9 pods × 400m. Only 2 fit per node, so 8 run on 4 nodes and 1 is Pending.
- Load profile per pod (CPU / memory): gateway 60m/40MB, catalog 90m/60MB, cart 30m/30MB,
  checkout 50m/40MB, worker 150m/80MB, plus the container's own baseline.
- Right-sized reference: 920m / 1024Mi for 9 pods, which fits on 2 nodes with room to spare.
- Priority demo: checkout to 12 runs out of memory on 2 nodes, so exactly one batch worker is preempted.
- Quota (2500m CPU, 3Gi) leaves room for that demo but blocks gateway at 30.
