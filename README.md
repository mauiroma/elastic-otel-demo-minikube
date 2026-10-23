# elastic-otel-demo-minikube

Operations manual: OpenTelemetry demo with Elastic on minikube (GCP VM + Elastic Cloud Hosted)

| | |
|---|---|
| **Purpose** | Build a full stack observability demo environment: the OpenTelemetry Astronomy Shop (Elastic fork) instrumented with EDOT, running on minikube in a GCP VM, with data sent to Elastic Cloud Hosted (ECH) |
| **Audience** | Solution Architects, Sales Engineers, anyone who needs to set up the demo |
| **Estimated time** | 60-90 minutes |
| **Expected result** | Demo reachable from a browser; VM, Kubernetes and application data visible in Kibana |

## Repository contents

```
elastic-otel-demo-minikube/
├── README.md                    # this operations manual
├── nginx/
│   └── otel-demo.conf           # nginx configuration (section 9.3)
├── helm/
│   └── demo-overrides.yml       # load generator overrides (section 11)
└── scripts/
    ├── install-prereqs.sh       # Docker, minikube, kubectl, Helm, git (sections 4-5)
    └── expose-nodeport.sh       # NodePort patch, rerun after every upgrade (section 9.1)
```

To use the files on the VM:

```bash
git clone https://github.com/<GITHUB_USER>/elastic-otel-demo-minikube.git ~/elastic-otel-demo-minikube
cd ~/elastic-otel-demo-minikube
```

## How to use this manual

Run the phases **in the order shown**. Each phase includes:

- **Goal**: what you achieve;
- **Procedure**: commands or steps in Kibana;
- **Verification**: the expected result before moving on to the next phase.

### Conventions

| Placeholder | Meaning |
|---|---|
| `VM_NAME` | GCP instance name |
| `ZONE` | GCP zone of the VM (e.g. `europe-west1-b`) |
| `VM_PUBLIC_IP` | External IP of the VM |
| `<VERSION>` | Elastic Agent version suggested by Kibana |
| `<FLEET_SERVER_URL>`, `<ENROLLMENT_TOKEN>` | Values copied from Fleet |
| `<GITHUB_USER>` | GitHub user hosting this repository |

Commands marked "on the VM" run in an SSH session (`gcloud compute ssh VM_NAME --zone ZONE`). Commands marked "on the Mac" run locally.

### Phase summary

| Section | Phase | Activity | Where |
|---|---|---|---|
| 3 | Phase 1 | `gCloud` agent policy, integrations and Elastic Agent installation | Kibana + VM |
| 4 | Phase 2 | Docker installation | VM |
| 5 | Phase 3 | minikube, kubectl, Helm, git installation | VM |
| 6 | Phase 4 | Start the minikube cluster | VM |
| 7 | Phase 5 | Retrieve OTLP endpoint and API key | Kibana |
| 8 | Phase 6 | Deploy EDOT and the demo | VM |
| 9 | Phase 7 | Access the demo through nginx | VM + Mac |
| 10-13 | | Endpoints, load generator, Kibana, demo scenarios | Reference |
| 14-15 | | Troubleshooting and teardown | Reference |

---

## 1. Architecture

```
Browser (Mac)
   │  http://otel-demo.test
   ▼
GCP VM (Ubuntu 26.04, e2-standard-4)
   ├── Elastic Agent (Fleet, gCloud policy) ──────────────┐
   │     System, Docker, Nginx, Elastic Defend,           │
   │     Universal Profiling                              │
   ├── nginx (basic auth)  ──►  NodePort 30080            │
   └── minikube (docker driver)                           │
         ├── ns opentelemetry-operator-system             │
         │     ├── OpenTelemetry Operator                 │
         │     ├── EDOT Collector DaemonSet  (kubeletstats, app telemetry)
         │     ├── EDOT Collector Cluster    (k8s_cluster, k8sobjects)
         │     └── EDOT Collector Gateway ───────────┐    │
         └── ns otel-demo                            │    │
               └── ~20 demo microservices            │    │
                                                     ▼    ▼
                          Elastic Cloud Hosted (Managed OTLP endpoint, Fleet Server, Kibana)
```

Observability covers two layers:

| Scope | Collected by |
|---|---|
| VM, Docker, nginx, security, profiling | Elastic Agent (`gCloud` policy) |
| Kubernetes nodes, pods, containers and events | EDOT Collector (`kubeletstats`, `k8s_cluster`, `k8sobjects`) |
| Application traces, metrics and logs | EDOT SDKs → EDOT Collector → Managed OTLP endpoint |

---

## 2. Requirements

### 2.1 GCP VM

| Resource | Value | Notes |
|---|---|---|
| Machine type | e2-standard-4 (4 vCPU, 16 GB RAM) | Enough for demos and PoCs. For smoother demos or load tests: e2-standard-8 |
| Boot disk | At least 48 GB | Expected usage 15-20 GB |
| Operating system | Ubuntu 26.04 LTS (resolute) | Supported by the official Docker repository |
| Network | External IP, port 80 reachable from your client | Required to access the demo through nginx |

### 2.2 Elastic Cloud Hosted

- ECH deployment **9.0 or later** (required for the Managed OTLP endpoint).
- **Fleet** enabled on the deployment (included in ECH).
- Permissions to create agent policies, integrations and API keys.

### 2.3 Local workstation (Mac)

- `gcloud` CLI authenticated against the GCP project.
- Administrator rights to edit `/etc/hosts`.

---

## 3. Phase 1: VM observability with Elastic Agent

**Goal**: create the `gCloud` agent policy, add the integrations and enroll the VM in Fleet. Do this first, so that VM data is visible in Kibana from the moment Docker, minikube and nginx are installed.

### 3.1 Integrations in the `gCloud` policy

| Integration | What it covers | Documentation |
|---|---|---|
| **System** | VM resources, processes, system logs and SSH/sudo access | [System integration](https://www.elastic.co/docs/reference/integrations/system) |
| **Docker** | The `minikube` container (the Kubernetes node seen from outside) and the Docker daemon | [Docker integration](https://www.elastic.co/docs/reference/integrations/docker) |
| **Nginx** | The reverse proxy in front of the demo: access logs, errors and metrics | [Nginx integration](https://www.elastic.co/docs/reference/integrations/nginx) |
| **Elastic Defend** | Endpoint security (EDR) for the VM | [Elastic Defend integration](https://www.elastic.co/docs/reference/integrations/endpoint) |
| **Universal Profiling Agent** | Continuous whole-system profiling of the VM, including processes inside minikube | [Get started with Universal Profiling](https://www.elastic.co/docs/solutions/observability/infra-and-hosts/get-started-with-universal-profiling) |

### 3.2 Create the `gCloud` agent policy

> Documentation: [Elastic Agent policies, Create a policy](https://www.elastic.co/docs/reference/fleet/agent-policy#create-a-policy)

1. In Kibana: **Fleet → Agent policies → Create agent policy**.
2. **Name**: `gCloud`.
3. Keep **Collect system logs and metrics** selected: it adds the System integration automatically.
4. In **Advanced options** keep the `default` namespace and agent monitoring (logs and metrics) enabled.
5. Click **Create agent policy**.

### 3.3 Add the integrations to the policy

> Documentation: [Add an integration to an Elastic Agent policy](https://www.elastic.co/docs/reference/fleet/add-integration-to-policy)

Common procedure for each integration:

1. **Integrations** → search for the integration → **Add <integration>**.
2. Configure it as described below.
3. In **Where to add this integration?** choose **Existing hosts** and the **`gCloud`** policy.
4. **Save and continue**.

**System**

> Documentation: [System integration](https://www.elastic.co/docs/reference/integrations/system)

Already added when the policy was created. Check that the following are enabled:

- **Collect logs from System instances**: syslog (`/var/log/syslog*`, `/var/log/messages*`) and auth (`/var/log/auth.log*`, `/var/log/secure*`);
- **Collect metrics from System instances**: all default metricsets.

**Docker**

> Documentation: [Docker integration](https://www.elastic.co/docs/reference/integrations/docker)

- **Hosts**: `unix:///var/run/docker.sock` (default).
- Keep all default metricsets enabled (container, cpu, memory, network, diskio, info, event).

**Nginx**

> Documentation: [Nginx integration](https://www.elastic.co/docs/reference/integrations/nginx)

- **Access logs**: `/var/log/nginx/access.log*`.
- **Error logs**: `/var/log/nginx/error.log*`.
- **Metrics (stubstatus)**: **Hosts** `http://127.0.0.1:80`, **Server status path** `/nginx_status`.

The `/nginx_status` location without basic auth is configured in section 9.3.

**Elastic Defend**

> Documentation: [Elastic Defend integration](https://www.elastic.co/docs/reference/integrations/endpoint), [Install Elastic Defend](https://www.elastic.co/docs/solutions/security/configure-elastic-defend/install-elastic-defend), [Event filters](https://www.elastic.co/docs/solutions/security/manage-elastic-defend/event-filters)

- **Integration name**: for example `defend-gcloud`.
- **Type of environment**: **Traditional Endpoints**.
- **Configuration settings**: **Essential EDR** is a good trade-off for a demo; **Complete EDR** collects more telemetry.
- With Docker and minikube, internal network traffic generates a very high volume of `endpoint.events.network`. To limit storage on ECH: in the Defend policy, **Events** section, disable **Network** for Linux, or create event filters for minikube internal traffic.

**Universal Profiling Agent**

> Documentation: [Get started with Universal Profiling](https://www.elastic.co/docs/solutions/observability/infra-and-hosts/get-started-with-universal-profiling)

1. Enable Universal Profiling on the deployment: in Kibana **Observability → Universal Profiling → Set up Universal Profiling**.
2. From the same page choose installation via **Elastic Agent / Fleet** and add the **Universal Profiling Agent** integration to the `gCloud` policy. The wizard provides the collector URL and secret token.

### 3.4 Install the agent on the VM

> Documentation: [Install Fleet-managed Elastic Agents](https://www.elastic.co/docs/reference/fleet/install-fleet-managed-elastic-agent)

1. In Kibana: **Fleet → Agents → Add agent**.
2. Select the **`gCloud`** policy.
3. Choose **Enroll in Fleet** and the **Linux Tar** platform.
4. Copy the suggested command and run it **on the VM**. It looks like this:

```bash
curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-<VERSION>-linux-x86_64.tar.gz
tar xzvf elastic-agent-<VERSION>-linux-x86_64.tar.gz
cd elastic-agent-<VERSION>-linux-x86_64
sudo ./elastic-agent install --url=<FLEET_SERVER_URL> --enrollment-token=<ENROLLMENT_TOKEN>
```

Always use the URL, version and token copied from Kibana. The agent version must be equal to or lower than the deployment version.

### 3.5 Verification

```bash
sudo elastic-agent status
```

- In **Fleet → Agents** the host shows as **Healthy** within a couple of minutes.
- **Infrastructure → Hosts** shows the VM with CPU, memory and disk.

### 3.6 Notes

- **Installation order**: Docker and nginx are installed in sections 4 and 9. Until then the Docker and Nginx integrations report connection errors: this is expected and resolves itself.
- **Docker**: the agent installed as a service runs as root and reads `/var/run/docker.sock` without extra configuration.
- **Policy changes**: every change made in Fleet is rolled out to the agent automatically, with no action needed on the VM.

---

## 4. Phase 2: Docker installation

**Goal**: install Docker Engine from the official repository, required by minikube with the docker driver. Run all commands **on the VM**.

> **Quick alternative**: the `scripts/install-prereqs.sh` script runs sections 4 and 5 in one go:
>
> ```bash
> ./scripts/install-prereqs.sh
> ```
>
> When it finishes, log out and back in over SSH and run the checks in 4.4 and 5.2.

### 4.1 Remove conflicting packages

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null
done
```

### 4.2 Configure the official Docker repository

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOT

sudo apt-get update
apt-cache policy docker-ce | head -5
```

**Intermediate check**: the `Candidate` field shows a `...~ubuntu.26.04~resolute` version. If it shows `(none)`, check the `apt-get update` output.

### 4.3 Install and set permissions

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker $USER
newgrp docker            # or log out and back in over SSH
```

Do not use `snap install docker`: its confinement causes problems with minikube.

### 4.4 Verification

```bash
docker version                # both Client and Server are shown
docker run hello-world        # prints "Hello from Docker!"
systemctl is-enabled docker   # returns "enabled"
```

---

## 5. Phase 3: minikube, kubectl, Helm and git installation

**Goal**: install the tools to create and manage the cluster. Commands **on the VM**.

### 5.1 Procedure

```bash
# minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# git
sudo apt-get install -y git
```

### 5.2 Verification

```bash
minikube version && kubectl version --client && helm version && git --version
```

---

## 6. Phase 4: start the minikube cluster

**Goal**: create the single-node Kubernetes cluster. Commands **on the VM**.

### 6.1 Procedure

```bash
minikube start --driver=docker --cpus=4 --memory=12g
```

With the docker driver the `--disk-size` flag is not needed: minikube uses the VM disk directly.

### 6.2 Verification

```bash
kubectl get nodes          # the minikube node is Ready
```

After a VM reboot, just run `minikube start` again.

---

## 7. Phase 5: retrieve endpoint and API key from ECH

**Goal**: get the credentials EDOT uses to send data to ECH.

### 7.1 Procedure

From Kibana:

1. **Add data → Application → OpenTelemetry**.
2. Copy the value of `OTEL_EXPORTER_OTLP_ENDPOINT`.
3. Click **Create an API Key** and copy the key.

Alternatively, from the Cloud Console: deployment → **Manage** → *Application endpoints, cluster and component IDs* → **Managed OTLP** → copy the public endpoint. If you create the API key manually, it needs at least the `event:write` privilege on the `apm` application.

### 7.2 Verification

The endpoint and API key are available and stored securely for the next phase.

---

## 8. Phase 6: deploy EDOT and the demo

**Goal**: install EDOT (operator and collectors) and the demo microservices. Commands **on the VM**.

### 8.1 Dedicated namespace

```bash
kubectl create namespace otel-demo
kubectl config set-context --current --namespace=otel-demo
```

EDOT is installed in `opentelemetry-operator-system` regardless. The demo services send data to the collector through its FQDN, so the separate namespace works without changes.

### 8.2 Clone the repository and deploy

```bash
git clone https://github.com/elastic/opentelemetry-demo.git ~/opentelemetry-demo
cd ~/opentelemetry-demo
./demo.sh k8s
```

The script asks for the endpoint and API key (section 7), saves them in `.env.override` and then:

1. adds the `open-telemetry` Helm repository;
2. creates the `elastic-secret-otel` secret in `opentelemetry-operator-system`;
3. installs EDOT with the `opentelemetry-kube-stack` chart and the `managed_otlp` values;
4. installs the demo with the `opentelemetry-demo` chart (release `my-otel-demo`) and the `kubernetes/elastic-helm/demo.yml` values.

### 8.3 Verification

```bash
kubectl get pods -n opentelemetry-operator-system
kubectl get pods -w
```

- All pods reach `Running` within a few minutes. A few initial restarts of the Java services (ad, fraud-detection, kafka) are normal.
- In Kibana, **APM → Services** lists the demo services.

For a pod in `CrashLoopBackOff` or `OOMKilled`:

```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name> --previous
```

---

## 9. Phase 7: access the demo through nginx

**Goal**: make the demo reachable from a browser with a host name, protected by basic auth.

Flow: Browser → `VM_PUBLIC_IP:80` → nginx with basic auth → `192.168.49.2:30080` (frontend-proxy NodePort).

### 9.1 Expose the frontend-proxy as a NodePort

On the VM:

```bash
kubectl patch svc frontend-proxy -n otel-demo \
  -p '{"spec":{"type":"NodePort","ports":[{"port":8080,"targetPort":8080,"nodePort":30080}]}}'
curl -I http://$(minikube ip):30080
```

Alternatively, from the repository folder: `./scripts/expose-nodeport.sh`.

A `helm upgrade` of the demo resets the service to ClusterIP: reapply the patch after every upgrade.

### 9.2 Install nginx and create the basic auth user

On the VM:

```bash
sudo apt-get install -y nginx apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd demo
```

### 9.3 nginx configuration

On the VM. Check that `192.168.49.2` matches the output of `minikube ip`.

The configuration is available in the repository as `nginx/otel-demo.conf`:

```bash
sudo cp nginx/otel-demo.conf /etc/nginx/sites-available/otel-demo
```

Alternatively, create it directly:

```bash
sudo tee /etc/nginx/sites-available/otel-demo > /dev/null <<'EOT'
server {
    listen 80;
    server_name otel-demo.test;

    auth_basic "OTel Demo";
    auth_basic_user_file /etc/nginx/.htpasswd;

    # Endpoint for the Elastic Agent Nginx integration (localhost only, no auth)
    location = /nginx_status {
        auth_basic off;
        stub_status;
        allow 127.0.0.1;
        allow ::1;
        deny all;
        access_log off;
    }

    location / {
        proxy_pass http://192.168.49.2:30080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
}
EOT
```

Enable the site:

```bash
sudo ln -sf /etc/nginx/sites-available/otel-demo /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
curl http://127.0.0.1/nginx_status
```

From now on the Nginx integration in the `gCloud` policy collects logs and `stubstatus` metrics.

### 9.4 Host name

On the Mac, map `otel-demo.test` to the VM IP:

```bash
echo "VM_PUBLIC_IP   otel-demo.test" | sudo tee -a /etc/hosts
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
dscacheutil -q host -a name otel-demo.test   # returns VM_PUBLIC_IP
```

Avoid the `.local` suffix, which macOS reserves for Bonjour/mDNS. The name only works on the Mac where it is configured: other users need to add it to their own `/etc/hosts`.

### 9.5 Verification

- Open http://otel-demo.test/ and enter the basic auth credentials: the Astronomy Shop appears.
- `curl http://127.0.0.1/nginx_status` on the VM returns nginx statistics.
- In Kibana the `nginx.access` and `nginx.stubstatus` data streams receive data.

---

## 10. Reference: endpoints

### 10.1 Demo (through nginx)

| URL | Service | Purpose | Available |
|---|---|---|---|
| http://otel-demo.test/ | frontend | Astronomy Shop | Yes |
| http://otel-demo.test/loadgen/ | load-generator (Locust) | Manage users and spawn rate, view statistics | Yes |
| http://otel-demo.test/feature/ | flagd-ui | Feature flags for fault injection | Yes |
| http://otel-demo.test/images/ | image-provider | Product images | Yes |
| http://otel-demo.test/flagservice/ | flagd | Feature flag API | Yes (API) |
| http://otel-demo.test/otlp-http/ | OTLP/HTTP collector | Browser-side telemetry | Unused (browser traffic disabled) |
| /jaeger/, /grafana/ | Jaeger, Grafana | Upstream backends | No, replaced by Kibana |
| /telemetry/, /opamp/, /profiles/, /chatbot/ | Extra components | Envoy routes | No, not included in the chart |

### 10.2 In-cluster

| Endpoint | Ports | Use |
|---|---|---|
| `opentelemetry-kube-stack-daemon-collector.opentelemetry-operator-system.svc.cluster.local` | 4317 gRPC, 4318 HTTP | EDOT collector for microservice telemetry (including services added later) |

### 10.3 Elastic Cloud Hosted

| Endpoint | Use |
|---|---|
| Kibana | APM, dashboards, Discover, Infrastructure, Fleet, Security |
| Managed OTLP endpoint | Destination of EDOT data (`elastic-secret-otel` secret) |
| Fleet Server | Management of the Elastic Agent on the VM |

---

## 11. Reference: load generator configuration

Chart defaults: `LOCUST_USERS=10`, `LOCUST_SPAWN_RATE=1`, `LOCUST_AUTOSTART=true`, memory limit 1500Mi.

### 11.1 Permanent change

Edit the values in the repository file `helm/demo-overrides.yml`:

```yaml
components:
  load-generator:
    envOverrides:
      - name: LOCUST_BROWSER_TRAFFIC_ENABLED
        value: "false"
      - name: LOCUST_USERS
        value: "5"
      - name: LOCUST_SPAWN_RATE
        value: "1"
    resources:
      limits:
        memory: 800Mi
```

Apply it after the Elastic fork `demo.yml` and reapply the NodePort patch:

```bash
helm upgrade my-otel-demo open-telemetry/opentelemetry-demo --version 0.40.7 \
  -f ~/opentelemetry-demo/kubernetes/elastic-helm/demo.yml \
  -f helm/demo-overrides.yml -n otel-demo
./scripts/expose-nodeport.sh
```

`envOverrides` is a list: the override file replaces the one in `demo.yml`, so `LOCUST_BROWSER_TRAFFIC_ENABLED` must be kept. For the same reason, do not use `--set` on `envOverrides`.

### 11.2 Temporary change

- From the UI: http://otel-demo.test/loadgen/, stop the test, change users and spawn rate, restart.
- From the CLI: `kubectl set env deployment/load-generator LOCUST_USERS=20` (overwritten by the next `helm upgrade`).

On an e2-standard-4, stay between 5 and 20 users: more users increase CPU usage and the data volume sent to ECH.

---

## 12. Reference: exploring the data in Kibana

### 12.1 Asset integrations to check

In **Integrations** make sure these are installed:

- **Kubernetes OpenTelemetry Assets**
- **System OpenTelemetry Assets**

They provide the dashboards for EDOT data. Dashboards for the `gCloud` policy integrations (System, Docker, Nginx) are installed together with the policy.

### 12.2 Where to look

| Layer | What | Where |
|---|---|---|
| Applications | Services, traces, errors, latency | APM → Services, Service map, Traces |
| Kubernetes | Cluster status | Dashboards → Kubernetes OTel dashboards |
| Kubernetes | Pod and container metrics | Kubernetes OTel dashboards, or Discover on `metrics-kubeletstatsreceiver.otel-*` |
| Kubernetes | Phases, restarts, replicas | Discover on `metrics-k8sclusterreceiver.otel-*` |
| VM | Host, CPU, memory, disk, processes | Infrastructure → Hosts, *[Metrics System]* dashboard |
| VM | `minikube` container and Docker daemon | *[Metrics Docker]* dashboard |
| VM | nginx access and performance | *[Logs Nginx]* and *[Metrics Nginx]* dashboards |
| VM | System logs and SSH access | Discover on `logs-system.syslog-*`, `logs-system.auth-*` |
| VM | Endpoint security | Security → Alerts, Explore → Hosts |
| VM | Continuous profiling | Observability → Universal Profiling |

### 12.3 Known limitations with EDOT

- **Infrastructure → Inventory → Kubernetes Pods / Docker Containers** are empty with EDOT (from 9.2): they only support the Elastic Agent data format. The Hosts view works.
- In the **Infrastructure** tab of an APM service, Hosts open the Hosts UI; Pods and Containers link to Discover. This is the expected behaviour for OTel services.
- Do not add the Elastic Agent Kubernetes integration: it would duplicate the data already collected by EDOT.

Check the service → pod correlation in Discover:

```
service.name : "checkout" and k8s.pod.name : *
```

---

## 13. Reference: demo scenarios with feature flags

From http://otel-demo.test/feature/:

| Flag | Effect | What to show in Kibana |
|---|---|---|
| `kafkaQueueProblems` | Adds a sleep to every message consumed by fraud-detection (value in ms) | Higher latency on consumer spans: an asynchronous problem while checkout stays healthy |
| `kafkaConsumerDead` | fraud-detection leaves the consumer group | Orders pile up in Kafka, consumer spans disappear |
| `loadGeneratorFloodHomepage` | Floods the frontend with requests | Throughput and latency anomalies in APM, request spike in nginx logs, CPU of the VM and the minikube container |

---

## 14. Troubleshooting

| Symptom | Check / fix |
|---|---|
| Agent not Healthy in Fleet | `sudo elastic-agent status`, `sudo elastic-agent logs` |
| Docker or Nginx integration errors right after installing the agent | Expected until Docker and nginx are installed (sections 4 and 9) |
| `nginx.stubstatus ... 401 Unauthorized` | Missing `/nginx_status` location with `auth_basic off` (section 9.3) |
| High volume of `endpoint.events.network` | Disable network events in the Elastic Defend policy or add event filters (section 3.3) |
| `permission denied ... /var/run/docker.sock` | `docker` group not active: log out and back in over SSH |
| `docker-ce Candidate: (none)` | Docker repository not configured: repeat section 4.2 |
| Pods `OOMKilled` | Lower `LOCUST_USERS`, scale the EDOT gateway to 1 replica, or increase minikube `--memory` |
| Java pods restarting at startup | Normal during the first minutes with 4 vCPUs |
| `otel-demo.test` not resolved | Check `/etc/hosts` and flush the DNS cache (section 9.4) |
| URL not reachable through nginx | `curl -I http://$(minikube ip):30080`, `sudo systemctl status nginx`, port 80 reachability on the VM |
| Demo unreachable after `helm upgrade` | The service is back to ClusterIP: `./scripts/expose-nodeport.sh` (section 9.1) |
| No EDOT data in Kibana | `kubectl logs -n opentelemetry-operator-system -l app.kubernetes.io/component=opentelemetry-collector --tail=50` |
| Disk almost full | `df -h /`, `docker system df`, `minikube ssh -- df -h /var` |

---

## 15. Teardown

On the VM:

```bash
cd ~/opentelemetry-demo
./demo.sh destroy k8s          # removes the demo and EDOT
minikube delete                # optional: deletes the cluster
sudo elastic-agent uninstall   # optional: removes the agent from the VM
```

In Kibana: **Fleet → Agents** → select the agent → **Unenroll**. If the `gCloud` policy is no longer needed: **Fleet → Agent policies → gCloud → Delete policy**.

On the Mac: remove the `otel-demo.test` line from `/etc/hosts`.

---

## 16. References

- [elastic/opentelemetry-demo (GitHub)](https://github.com/elastic/opentelemetry-demo)
- [Elastic fork demo.yml](https://raw.githubusercontent.com/elastic/opentelemetry-demo/main/kubernetes/elastic-helm/demo.yml)
- [Elastic Agent policies](https://www.elastic.co/docs/reference/fleet/agent-policy)
- [Add an integration to an Elastic Agent policy](https://www.elastic.co/docs/reference/fleet/add-integration-to-policy)
- [Install Fleet-managed Elastic Agents](https://www.elastic.co/docs/reference/fleet/install-fleet-managed-elastic-agent)
- [System integration](https://www.elastic.co/docs/reference/integrations/system)
- [Docker integration](https://www.elastic.co/docs/reference/integrations/docker)
- [Nginx integration](https://www.elastic.co/docs/reference/integrations/nginx)
- [Elastic Defend integration](https://www.elastic.co/docs/reference/integrations/endpoint)
- [Install Elastic Defend](https://www.elastic.co/docs/solutions/security/configure-elastic-defend/install-elastic-defend)
- [Elastic Defend event filters](https://www.elastic.co/docs/solutions/security/manage-elastic-defend/event-filters)
- [Get started with Universal Profiling](https://www.elastic.co/docs/solutions/observability/infra-and-hosts/get-started-with-universal-profiling)
- [Deploy EDOT for Kubernetes observability](https://www.elastic.co/docs/solutions/observability/get-started/opentelemetry/use-cases/kubernetes/deployment)
- [Prerequisites and compatibility (EDOT Kubernetes)](https://www.elastic.co/docs/solutions/observability/get-started/opentelemetry/use-cases/kubernetes/prerequisites-compatibility)
- [Customize the EDOT Kubernetes configuration](https://www.elastic.co/docs/solutions/observability/get-started/opentelemetry/use-cases/kubernetes/customization)
- [Default configuration of the EDOT Collector (Kubernetes)](https://www.elastic.co/docs/reference/edot-collector/config/default-config-k8s)
- [Quickstart: Managed OTLP endpoint on ECH/Serverless](https://www.elastic.co/docs/solutions/observability/get-started/quickstart-elastic-cloud-otel-endpoint)
- [Applications UI: Infrastructure tab](https://www.elastic.co/guide/en/kibana/current/infrastructure.html)
- [Kubernetes Pods and Docker Containers views empty when using EDOT](https://www.elastic.co/docs/troubleshoot/observability/troubleshooting-infrastructure-monitoring/kubernetes-pods-docker-containers-empty-otel)
- [OpenTelemetry Demo Helm chart 0.40.7 values.yaml](https://raw.githubusercontent.com/open-telemetry/opentelemetry-helm-charts/opentelemetry-demo-0.40.7/charts/opentelemetry-demo/values.yaml)
- [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
