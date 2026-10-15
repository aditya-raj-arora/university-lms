# Q1 – University Learning Management Portal
### Versioned releases, health checks and automated rollback

## Repository layout

```
university-lms/
├── index.html            Portal page (courses, faculty, resources, announcements, exams)
├── styles.css
├── nginx.conf            Serves the site and exposes /healthz
├── Dockerfile
├── deployment.yaml       Deployment – 2 replicas, rolling update, readiness/liveness probes
├── service.yaml          NodePort Service on 30081
├── Jenkinsfile           Checkout → Build → Test → Push → Deploy → Health Check → Promote
└── tests/smoke-test.sh   Content + asset checks, run inside the container
```

**Before you start:** replace `YOUR_DOCKERHUB_USERNAME` in `Jenkinsfile` and `deployment.yaml` with your Docker Hub username.

Release design: every Jenkins build produces an immutable tag `v1.0.<BUILD_NUMBER>`. The tag is shown in the page footer (from `version.txt`), recorded in `kubectl rollout history` through the `change-cause` annotation, and only promoted to `stable`/`latest` after the Kubernetes health checks pass.

---

## Step 1 – Create the Git repository

```bash
cd university-lms
git init -b main
git add .
git commit -m "University LMS portal v1.0.0"
```

Create an empty repository named `university-lms` on GitHub, then:

```bash
git remote add origin https://github.com/<github-user>/university-lms.git
git push -u origin main
```

## Step 2 – Build the Docker image

```bash
docker build --build-arg APP_VERSION=v1.0.0 -t <dockerhub-user>/university-lms:v1.0.0 -t <dockerhub-user>/university-lms:latest .
docker images <dockerhub-user>/university-lms
```

## Step 3 – Run the container and verify locally

```bash
docker run -d --name lms-local -p 8080:80 <dockerhub-user>/university-lms:v1.0.0
docker ps
```

Open **http://localhost:8080**. The footer should read `Release: v1.0.0`. After ~15 s `docker ps` shows the container as `(healthy)`.

```bash
docker exec -i lms-local sh -s http://127.0.0.1 < tests/smoke-test.sh
docker rm -f lms-local
```

## Step 4 – Push the image to Docker Hub

```bash
docker login
docker push <dockerhub-user>/university-lms:v1.0.0
docker push <dockerhub-user>/university-lms:latest
```

## Step 5 – Enable Kubernetes in Docker Desktop

Docker Desktop → **Settings → Kubernetes → Enable Kubernetes** (choose the *kubeadm* cluster type if asked) → **Apply & Restart**. Then:

```bash
kubectl config use-context docker-desktop
kubectl get nodes
```

The node `docker-desktop` must be `Ready`.

## Step 6 – Create the Deployment (2 replicas)

```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/university-lms
kubectl get deployment university-lms
```

## Step 7 – Configure Jenkins credentials

Install Jenkins on the same machine as Docker Desktop, with the **Pipeline**, **Git** and **Credentials Binding** plugins. `docker` and `kubectl` must be on the PATH of the Jenkins process.

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

| Kind | ID | Value |
|---|---|---|
| Username with password | `dockerhub-creds` | Docker Hub username + a Docker Hub **access token** (Account Settings → Personal access tokens) |
| Secret file | `kubeconfig` | Upload `C:\Users\<you>\.kube\config` (Windows) or `~/.kube/config` (macOS/Linux) |

## Step 8 – Create the Jenkins pipeline

1. **New Item** → name `university-lms-pipeline` → **Pipeline** → OK.
2. **Pipeline → Definition:** *Pipeline script from SCM* → SCM *Git* → Repository URL of your repo → Branch `*/main` → Script Path `Jenkinsfile`.
3. Save → **Build Now**.

The pipeline stages are: **Checkout → Build Image → Test Image → Push Image → Deploy to Kubernetes → Health Check → Promote Stable Release**.

The first build registers the `pollSCM` trigger, so every later commit pushed to GitHub starts a build automatically within ~2 minutes. (For instant triggering, expose Jenkins with ngrok and add a GitHub webhook to `https://<ngrok-url>/github-webhook/`.)

## Step 9 – Create the NodePort Service

The pipeline applies it automatically; to create it manually:

```bash
kubectl apply -f service.yaml
kubectl get service university-lms
```

Expected: `TYPE NodePort`, `PORT(S) 80:30081/TCP`.

## Step 10 – Verify through the NodePort

Open **http://localhost:30081** — the footer shows the release deployed by Jenkins, e.g. `Release: v1.0.1`.

```bash
curl http://localhost:30081/healthz        # Windows PowerShell: curl.exe
curl http://localhost:30081/version.txt
```

## Step 11 – Verify both Pods are running

```bash
kubectl get pods -l app=university-lms -o wide
```

Expected: **2 pods, `READY 1/1`, `STATUS Running`**.

```bash
kubectl rollout history deployment/university-lms
```

---

## Faulty release and automated rollback

### 1. Introduce the faulty version

In `nginx.conf`, change the health endpoint so the new release reports itself unhealthy:

```nginx
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 500 "unhealthy\n";
    }
```

```bash
git commit -am "Release with broken health endpoint"
git push
```

### 2. What the pipeline does

- **Build / Test / Push** succeed – the page content is fine, so the image passes the smoke tests.
- **Deploy** applies the new tag. Because the strategy is `maxUnavailable: 0`, the 2 old pods keep serving traffic while one new pod starts.
- The new pod's **readiness probe fails** (`/healthz` returns 500), so it never becomes Ready and the rollout exceeds `progressDeadlineSeconds`.
- **Health Check** detects the failed rollout, prints pod status and warning events, runs `kubectl rollout undo`, waits for the previous revision, and marks the build **FAILED**. The faulty tag is never promoted to `stable`/`latest`.

### 3. Identify the failed rollout (evidence for the report)

From the Jenkins console:

```
error: deployment "university-lms" exceeded its progress deadline
```

From the terminal (run while the rollout is in progress, or inspect the events afterwards):

```bash
kubectl get pods -l app=university-lms
kubectl describe pod <new-pod-name>        # Readiness probe failed: HTTP probe failed with statuscode: 500
kubectl get events --field-selector type=Warning --sort-by=.lastTimestamp
kubectl rollout history deployment/university-lms
```

### 4. Demonstrate the restored application

```bash
kubectl rollout status deployment/university-lms
kubectl get pods -l app=university-lms          # 2/2 Running, previous image
kubectl get deployment university-lms -o jsonpath="{.spec.template.spec.containers[0].image}"
```

Open **http://localhost:30081** – the page loads and the footer shows the **previous stable release** number.

### 5. Restore the repository

```bash
git revert --no-edit HEAD
git push
```

The next build deploys a healthy release and promotes it to `stable`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `docker: command not found` / `kubectl` not recognised in Jenkins | Add Docker's and kubectl's folders to the system PATH and restart Jenkins. |
| Jenkins (Windows service) cannot reach Docker | `services.msc` → Jenkins → **Log On** → run as your Windows user account → restart. |
| `docker login` fails with a credential-store error | Remove the `"credsStore"` line from `~/.docker/config.json` of the Jenkins user. |
| NodePort not reachable on localhost | Use the kubeadm cluster type in Docker Desktop's Kubernetes settings. |
