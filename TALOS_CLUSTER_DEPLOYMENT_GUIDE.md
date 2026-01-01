# Talos Cluster Deployment Guide with Omni, Longhorn, and Cloudflare Tunnel

## Overview
This guide provides the complete, tested steps to deploy a 5-node Talos Linux cluster using Omni with:
- Cilium CNI with KubeSpan
- Longhorn distributed storage on dedicated 500GB disks
- Cloudflare Tunnel for external application access
- Domain: <yourdomain.com>

## Prerequisites
- 5 physical nodes with Dell hardware
- Each node has a 500GB CT500MX500SSD1 SSD for storage
- Omni account and omnictl installed
- kubectl installed
- helm installed
- Access to GitHub for storing configurations
- Cloudflare account with <yourdomain.com> domain

## Step 1: Deploy the Cluster

### 1.1 Create Cluster Template

The cluster template is stored in your GitHub repository:

**File location**: [`github.com/HomeLabJunkie/omni/k8s-cluster-template.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/k8s-cluster-template.yaml)

This template defines:
- 5-node cluster (3 control plane, 2 workers)
- Workload scheduling enabled on control planes
- Cilium CNI with KubeSpan enabled
- Kubernetes v1.35.0 and Talos v1.12.0
- System extensions: iscsi-tools, util-linux-tools
- Metrics server configuration

### 1.2 Sync the Cluster Template

```bash
omnictl cluster template sync --file k8s-cluster-template.yaml
```

Wait for cluster to initialize:

```bash
# Monitor cluster creation
omnictl get clusters -w

# Once running, get kubeconfig
omnictl kubeconfig --cluster k8s-talos-cluster --merge

# Verify cluster is ready
kubectl get nodes
```

## Step 2: Configure Storage Disks

### 2.1 Apply Machine Patches for Storage Disks

The machine patches configure the 500GB CT500MX500SSD1 disks on each node.

**File location**: [`github.com/HomeLabJunkie/omni/patches/machine-patches.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/patches/machine-patches.yaml)

These patches:
- Mount each node's 500GB SSD at `/var/mnt/storage`
- Configure kubelet extra mounts for Longhorn
- Apply to all 5 nodes (omni-talos-1 through omni-talos-5)

### 2.2 Apply the Patches

```bash
omnictl apply -f machine-patches.yaml
```

Verify patches are applied:

```bash
omnictl get configpatches | grep storage-disk
```

You should see all 5 storage disk patches (500-231 through 500-235).

## Step 3: Install Longhorn

### 3.1 Create Longhorn Values File

The Longhorn Helm values file is stored in your GitHub repository:

**File location**: [`github.com/HomeLabJunkie/omni/longhorn-values.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/longhorn-values.yaml)

This configuration includes:
- Default data path: `/var/mnt/storage`
- PodSecurity labels for privileged namespace
- Cilium webhook compatibility fix (`internalTrafficPolicy: Cluster`)
- Omni service exposer annotations for UI access
- Volume mounts for the storage path

### 3.2 Install Longhorn via Helm

The Helm install command is stored in your GitHub repository:

**File location**: [`github.com/HomeLabJunkie/omni/homelab/helm-installs/longhorn-install.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/homelab/helm-installs/longhorn-install.yaml)

```bash
# Add Longhorn repository
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Install Longhorn using your values file
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  -f https://raw.githubusercontent.com/HomeLabJunkie/omni/main/longhorn-values.yaml
```

### 3.3 Fix Namespace PodSecurity Labels

The namespace needs privileged pod security labels:

```bash
kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace longhorn-system pod-security.kubernetes.io/audit=privileged --overwrite
kubectl label namespace longhorn-system pod-security.kubernetes.io/warn=privileged --overwrite
```

### 3.4 Restart Longhorn Manager Daemonset

```bash
kubectl rollout restart daemonset longhorn-manager -n longhorn-system
```

### 3.5 Wait for Longhorn Pods to be Running

```bash
kubectl get pods -n longhorn-system -w
```

Wait until all pods are running. You should see:
- longhorn-manager pods (daemonset - 5 pods)
- longhorn-driver-deployer
- longhorn-ui pods
- instance-manager pods

### 3.6 Add Storage Disks to Longhorn Nodes

Create and run the disk configuration script:

```bash
cat > /tmp/add-longhorn-disks.sh <<'EOF'
#!/bin/bash
for node in omni-talos-1 omni-talos-2 omni-talos-3 omni-talos-4 omni-talos-5; do
  kubectl -n longhorn-system patch nodes.longhorn.io/$node --type=json -p='[
    {
      "op": "replace",
      "path": "/spec/disks",
      "value": {
        "default-disk": {
          "allowScheduling": true,
          "evictionRequested": false,
          "path": "/var/mnt/storage",
          "storageReserved": 0,
          "tags": []
        }
      }
    }
  ]'
  echo "Patched $node"
done
EOF

chmod +x /tmp/add-longhorn-disks.sh
/tmp/add-longhorn-disks.sh
```

### 3.7 Verify Disks are Configured

```bash
# Check that disks are configured
kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep -A10 "disks:"

# Verify nodes are ready
kubectl get nodes.longhorn.io -n longhorn-system
```

All nodes should show `READY: True` and `SCHEDULABLE: True`.

### 3.8 Configure S3 Backup Target

**Note**: S3 credentials and configuration details are stored in your Trilium Notes application for reference.

**Backup Target Configuration**:
- S3 URL: `s3://longhorn@us-east-1/`
- Secret Name: `longhorn-minio-credentials`

Apply your S3 backup credentials from your LOCAL GitHub repository:

```bash
# Apply the S3 credentials secret
# File location: helm-installs/s3-backup-creds.yaml in your LOCAL GitHub repo 
# (.gitignore does not upload this file to the public repo)
kubectl apply -f s3-backup-creds.yaml
```

Configure the backup target in Longhorn:

```bash
# Set the backup target
kubectl -n longhorn-system patch settings.longhorn.io backup-target --type=merge -p '{"value":"s3://longhorn@us-east-1/"}'

# Set the backup target credential secret
kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret --type=merge -p '{"value":"longhorn-minio-credentials"}'
```

Verify the backup target is configured:

```bash
kubectl -n longhorn-system get settings.longhorn.io backup-target -o yaml
kubectl -n longhorn-system get settings.longhorn.io backup-target-credential-secret -o yaml
```

You should see the S3 backup target configured in the Longhorn UI under Settings → General → Backup Target.

## Step 4: Configure Cloudflare Tunnel

### 4.1 Install cloudflared on Development Workstation

On your Omni development workstation (with Homebrew installed):

```bash
# Install cloudflared
brew install cloudflare/cloudflare/cloudflared

# Verify installation
cloudflared --version
```

### 4.2 Authenticate with Cloudflare

```bash
# Login to Cloudflare (opens browser)
cloudflared tunnel login

# This will:
# 1. Open your browser
# 2. Ask you to select your Cloudflare account
# 3. Choose the <yourdomain.com> domain
# 4. Download cert.pem to ~/.cloudflared/
```

### 4.3 Create Cloudflare Tunnel

```bash
# Create the tunnel
cloudflared tunnel create k8s-talos-tunnel

# This will output:
# - Tunnel ID (e.g., <YOUR_TUNNEL_ID>)
# - Credentials file location: ~/.cloudflared/<TUNNEL_ID>.json

# Display the credentials (you'll need these for the Kubernetes secret)
cat ~/.cloudflared/<TUNNEL_ID>.json
```

**Save the Tunnel ID** - you'll need it for the next steps.

### 4.4 Create Cloudflare Tunnel Secret

**Note**: Cloudflare Tunnel configuration files are stored in your LOCAL GitHub repository and are not published to the public repo.

**File location**: `omni/homelab/secrets/cloudflare-tunnel-secret.yaml` (gitignored via `*/secrets/*`)

Replace the values with your tunnel credentials from step 4.3:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-secret
  namespace: cloudflare
type: Opaque
stringData:
  credentials.json: |
    {
      "AccountTag": "YOUR_ACCOUNT_TAG",
      "TunnelSecret": "YOUR_TUNNEL_SECRET",
      "TunnelID": "<YOUR_TUNNEL_ID>"
    }
```

### 4.5 Create Cloudflare Tunnel Deployment

**File location**: `omni/homelab/secrets/cloudflared-deployment.yaml` (gitignored via `*/secrets/*`)

**Important**: The deployment includes DNS configuration to properly resolve internal Kubernetes service names.

**Note**: Routes are managed through the Cloudflare Dashboard, not via ConfigMap. This deployment uses a minimal config.

Update the ConfigMap to use minimal configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflare
data:
  config.yaml: |
    tunnel: <YOUR_TUNNEL_ID>
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
```

Create the deployment:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflare
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      dnsPolicy: ClusterFirst
      dnsConfig:
        searches:
          - longhorn-system.svc.cluster.local
          - svc.cluster.local
          - cluster.local
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        args:
        - tunnel
        - --config
        - /etc/cloudflared/config/config.yaml
        - run
        livenessProbe:
          httpGet:
            path: /ready
            port: 2000
          failureThreshold: 1
          initialDelaySeconds: 10
          periodSeconds: 10
        volumeMounts:
        - name: config
          mountPath: /etc/cloudflared/config
          readOnly: true
        - name: credentials
          mountPath: /etc/cloudflared/creds
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: cloudflared-config
      - name: credentials
        secret:
          secretName: cloudflared-secret
```

### 4.6 Deploy Cloudflare Tunnel

```bash
# Create namespace
kubectl create namespace cloudflare

# Apply the minimal config ConfigMap
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflare
data:
  config.yaml: |
    tunnel: <YOUR_TUNNEL_ID>
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
EOF

# Apply secret (replace with your credentials first)
kubectl apply -f cloudflare-tunnel-secret.yaml

# Apply deployment
kubectl apply -f cloudflared-deployment.yaml

# Verify deployment
kubectl get pods -n cloudflare

# Check logs - you should see "Registered tunnel connection" messages
kubectl logs -n cloudflare -l app=cloudflared
```

Expected log output:
```
INF Registered tunnel connection connIndex=0 connection=... location=... protocol=quic
INF Registered tunnel connection connIndex=1 connection=... location=... protocol=quic
```

### 4.7 Configure Public Hostname Routes in Cloudflare Dashboard

Routes are managed through the Cloudflare Zero Trust Dashboard, which provides dynamic configuration without needing to redeploy pods.

**Step-by-step instructions:**

1. **Access Cloudflare Zero Trust Dashboard**
   - Log into your Cloudflare account
   - Go to **Zero Trust** → **Networks** → **Tunnels**
   - Click on your tunnel: `k8s-talos-tunnel`

2. **Add Public Hostname for Longhorn**
   - Click the **Public Hostname** tab
   - Click **Add a public hostname**
   - Configure the route:
     - **Subdomain**: `longhorn`
     - **Domain**: Select `<yourdomain.com>` from dropdown
     - **Path**: Leave empty
     - **Service**:
       - **Type**: `HTTP`
       - **URL**: `longhorn-frontend.longhorn-system:80`
   
   **Important**: Use the short service name format `service-name.namespace:port` (NOT the full FQDN `*.svc.cluster.local`). The DNS search domains in the cloudflared deployment will complete it properly.

3. **Save the Route**
   - Click **Save hostname**
   - The tunnel will automatically update with the new route (check logs to confirm)

4. **Verify the Route**
   ```bash
   # Watch the cloudflared logs to see the configuration update
   kubectl logs -n cloudflare -l app=cloudflared --tail=20
   
   # You should see:
   # INF Updated to new configuration config="{\"ingress\":[{\"hostname\":\"longhorn.<yourdomain.com>\"...
   ```

5. **DNS Configuration**
   - Cloudflare automatically creates a CNAME record when you add a public hostname
   - Verify in **DNS** → **Records**:
     ```
     longhorn CNAME <YOUR_TUNNEL_ID>.cfargotunnel.com (Proxied)
     ```

6. **Add Additional Services**
   - Repeat steps 2-5 for each service you want to expose
   - Examples:
     - **Service**: `app-service.app-namespace:8080`
     - **Subdomain**: `app`
     - **Domain**: `<yourdomain.com>`

### 4.8 Configure Cloudflare Security Settings

For the tunnel to work properly, configure these settings in your Cloudflare dashboard:

1. **SSL/TLS Settings**:
   - Go to **SSL/TLS** → **Overview**
   - Set to **"Full"** or **"Flexible"** (NOT "Full (strict)" since internal services use HTTP)

2. **Security Settings**:
   - Go to **Security** → **Settings**
   - Set **Security Level** to **"Medium"** or **"Essentially Off"** for testing
   - Disable **Bot Fight Mode** if it's blocking legitimate traffic

3. **Verify DNS**:
   - Go to **DNS** → **Records**
   - Verify the CNAME record exists:
     ```
     longhorn CNAME YOUR_TUNNEL_ID.cfargotunnel.com (Proxied)
     ```

### 4.9 Verify Access

```bash
# Test the tunnel
curl -I https://longhorn.<yourdomain.com>

# You should see HTTP/2 200 OK
```

Access the Longhorn UI in your browser:
```
https://longhorn.<yourdomain.com>
```

## Step 5: Secure Applications with Basic Authentication

### 5.1 Overview

This step adds an nginx reverse proxy with basic authentication to protect Longhorn and other applications. The traffic flow will be:

```
User → Cloudflare Tunnel → nginx (with auth) → Application
```

### 5.2 Install htpasswd Tool

On your Omni development workstation (Ubuntu):

```bash
# Install apache2-utils which includes htpasswd
sudo apt-get update
sudo apt-get install -y apache2-utils

# Verify installation
htpasswd -h
```

### 5.3 Generate Basic Auth Credentials

```bash
# Create a password file with a user
# Replace 'admin' with your desired username
htpasswd -c auth admin

# You'll be prompted to enter and confirm a password
# This creates a file called 'auth' with the encrypted password
```

### 5.4 Create Kubernetes Secret for Basic Auth

```bash
# Create secret in the longhorn-system namespace
kubectl create secret generic basic-auth \
  --from-file=auth \
  -n longhorn-system

# Verify the secret was created
kubectl get secret basic-auth -n longhorn-system
```

### 5.5 Deploy nginx Auth Proxy for Longhorn

Create the nginx deployment with ConfigMap:

**File: `nginx-auth-proxy-longhorn.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-auth-config
  namespace: longhorn-system
data:
  nginx.conf: |
    events {
      worker_connections 1024;
    }
    
    http {
      server {
        listen 80;
        server_name _;
        
        # Basic auth configuration
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/auth;
        
        # Proxy to Longhorn
        location / {
          proxy_pass http://longhorn-frontend:80;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-auth-proxy
  namespace: longhorn-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-auth-proxy
  template:
    metadata:
      labels:
        app: nginx-auth-proxy
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        - name: auth
          mountPath: /etc/nginx/auth
          subPath: auth
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-auth-config
      - name: auth
        secret:
          secretName: basic-auth
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-auth-proxy
  namespace: longhorn-system
spec:
  selector:
    app: nginx-auth-proxy
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
```

Deploy the nginx proxy:

```bash
# Apply the deployment
kubectl apply -f nginx-auth-proxy-longhorn.yaml

# Verify pods are running
kubectl get pods -n longhorn-system -l app=nginx-auth-proxy

# Check service
kubectl get svc nginx-auth-proxy -n longhorn-system
```

### 5.6 Update Cloudflare Tunnel Route

Update the Longhorn route in Cloudflare Dashboard to point to the nginx proxy instead of Longhorn directly:

1. Go to **Zero Trust** → **Networks** → **Tunnels**
2. Click on your tunnel: `k8s-talos-tunnel`
3. Go to **Public Hostname** tab
4. Edit the `longhorn.<yourdomain.com>` route
5. Update the **Service** configuration:
   - **Type**: `HTTP`
   - **URL**: `nginx-auth-proxy.longhorn-system:80`
   
   **Important**: Use exactly `nginx-auth-proxy.longhorn-system:80` (no `http://` prefix)

6. Save the changes

7. Verify the configuration update in cloudflared logs:
   ```bash
   kubectl logs -n cloudflare -l app=cloudflared --tail=20
   ```
   
   You should see:
   ```
   INF Updated to new configuration config="{\"ingress\":[{\"hostname\":\"longhorn.<yourdomain.com>\",\"originRequest\":{},\"service\":\"http://nginx-auth-proxy.longhorn-system:80\"}...
   ```

### 5.7 Test Authentication

```bash
# Test without credentials (should fail with 401)
curl -I https://longhorn.<yourdomain.com>
# Expected: HTTP/2 401 Unauthorized

# Test with credentials (should succeed)
curl -I -u admin:yourpassword https://longhorn.<yourdomain.com>
# Expected: HTTP/2 200 OK
```

Access in browser:
- Navigate to `https://longhorn.<yourdomain.com>`
- You'll be prompted for username and password
- Enter the credentials you created in step 5.3

### 5.8 Add Authentication to Additional Applications

To protect additional applications, you can create separate nginx deployments in their respective namespaces or create a dedicated `auth-proxy` namespace for all authentication proxies.

**Example: Protecting an app in its own namespace**

For an application in namespace `app-namespace` with service `app-service:8080`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-auth-config-app
  namespace: app-namespace
data:
  nginx.conf: |
    events {
      worker_connections 1024;
    }
    
    http {
      server {
        listen 80;
        server_name _;
        
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/auth;
        
        location / {
          proxy_pass http://app-service:8080;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-auth-proxy-app
  namespace: app-namespace
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-auth-proxy-app
  template:
    metadata:
      labels:
        app: nginx-auth-proxy-app
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        - name: auth
          mountPath: /etc/nginx/auth
          subPath: auth
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-auth-config-app
      - name: auth
        secret:
          secretName: basic-auth
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-auth-proxy-app
  namespace: app-namespace
spec:
  selector:
    app: nginx-auth-proxy-app
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
```

**Important**: You'll need to create the `basic-auth` secret in each namespace where you deploy an auth proxy:

```bash
# Create the secret in the app namespace
kubectl create secret generic basic-auth \
  --from-file=auth \
  -n app-namespace
```

Then configure Cloudflare Tunnel to route to `nginx-auth-proxy-app.app-namespace:80`

### 5.9 Managing Users

To add or update users:

```bash
# Add a new user to existing auth file
htpasswd auth newuser

# Update the secret in each namespace where it's used
kubectl create secret generic basic-auth \
  --from-file=auth \
  -n longhorn-system \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart nginx pods to pick up the new credentials
kubectl rollout restart deployment nginx-auth-proxy -n longhorn-system
```

To remove a user:

```bash
# Remove user from auth file
htpasswd -D auth username

# Update the secret
kubectl create secret generic basic-auth \
  --from-file=auth \
  -n longhorn-system \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart nginx pods
kubectl rollout restart deployment nginx-auth-proxy -n longhorn-system
```

## Step 5: Secure Applications with Basic Authentication

### 5.1 Overview

This step adds nginx-based basic authentication to protect web applications exposed through Cloudflare Tunnel. This provides a simple username/password login before accessing services like Longhorn.

### 5.2 Install Apache Utils (for htpasswd)

On your development workstation:

```bash
# Install apache2-utils for htpasswd command
# On macOS with Homebrew:
brew install httpd

# On Ubuntu/Debian:
# sudo apt-get install apache2-utils
```

### 5.3 Create htpasswd Credentials

```bash
# Create htpasswd file with username
htpasswd -c auth <username>

# You'll be prompted to enter a password
# This creates a file named 'auth' with encrypted credentials

# View the generated hash
cat auth
```

### 5.4 Create Basic Auth Secret

Create a Kubernetes secret with the htpasswd credentials:

```bash
# Create the secret in the longhorn-system namespace
kubectl create secret generic basic-auth \
  --from-file=auth \
  -n longhorn-system

# Verify the secret
kubectl get secret basic-auth -n longhorn-system
```

### 5.5 Deploy nginx Auth Proxy

Create the nginx deployment that will proxy requests to Longhorn with basic auth:

**File location**: `omni/homelab/infrastructure/nginx-auth-proxy-longhorn.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-auth-proxy
  namespace: longhorn-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-auth-proxy
  template:
    metadata:
      labels:
        app: nginx-auth-proxy
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        - name: auth
          mountPath: /etc/nginx/auth
          readOnly: true
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-auth-config
      - name: auth
        secret:
          secretName: basic-auth
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-auth-proxy
  namespace: longhorn-system
spec:
  selector:
    app: nginx-auth-proxy
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-auth-config
  namespace: longhorn-system
data:
  nginx.conf: |
    events {
      worker_connections 1024;
    }
    
    http {
      server {
        listen 80;
        
        location / {
          auth_basic "Restricted Access";
          auth_basic_user_file /etc/nginx/auth;
          
          proxy_pass http://longhorn-frontend:80;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        }
      }
    }
```

Apply the configuration:

```bash
kubectl apply -f nginx-auth-proxy-longhorn.yaml

# Verify the deployment
kubectl get pods -n longhorn-system -l app=nginx-auth-proxy
kubectl get svc nginx-auth-proxy -n longhorn-system
```

### 5.6 Update Cloudflare Tunnel Route

Update the Cloudflare Tunnel route to point to the nginx auth proxy instead of directly to Longhorn:

1. Go to **Zero Trust** → **Networks** → **Tunnels**
2. Click on `k8s-talos-tunnel`
3. Go to **Public Hostname** tab
4. Edit the `longhorn.<yourdomain.com>` route
5. Update the **Service URL** to: `nginx-auth-proxy.longhorn-system:80`
6. Click **Save hostname**

### 5.7 Verify Authentication

```bash
# Test without credentials (should fail with 401)
curl -I https://longhorn.<yourdomain.com>

# Should return: HTTP/2 401 Unauthorized

# Test with credentials (should succeed)
curl -u <username>:<password> -I https://longhorn.<yourdomain.com>

# Should return: HTTP/2 200 OK
```

Access in browser:
- Navigate to `https://longhorn.<yourdomain.com>`
- You'll be prompted for username and password
- Enter the credentials you created in step 5.3
- You should now see the Longhorn UI

### 5.8 Reusable Pattern for Other Applications

To add basic auth to other applications, follow this pattern:

1. **Create htpasswd secret** in the application's namespace
2. **Deploy nginx auth proxy** with the ConfigMap pointing to your application's service
3. **Expose the nginx proxy** instead of the application directly
4. **Update Cloudflare route** to point to `nginx-auth-proxy.<namespace>:80`

Example for a different app:

```yaml
# In the ConfigMap nginx.conf, change the proxy_pass line:
proxy_pass http://<your-app-service>:<port>;
```

**Security Notes**:
- Basic auth credentials are transmitted securely over HTTPS via Cloudflare Tunnel
- For production use, consider implementing OAuth2/OIDC with Authentik or similar
- Rotate passwords periodically by regenerating the htpasswd file and updating the secret

