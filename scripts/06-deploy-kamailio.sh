#!/bin/bash
# ---------------------------
# Kamailio SIP Load Balancer Deployment for LiveKit
# This script deploys Kamailio with ConfigMap, RBAC, Deployment, and NLB Service
# ---------------------------

set -euo pipefail

echo "📞 Kamailio SIP Load Balancer Deployment for LiveKit"
echo "===================================================="
echo "📅 Started at: $(date)"
echo ""

# =============================================================================
# VARIABLES CONFIGURATION
# =============================================================================

# --- Required Variables ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# --- Kamailio Configuration ---
LIVEKIT_NAMESPACE="livekit"
SIP_PORT="${SIP_PORT:-5060}"

# --- Resource Configuration ---
KAMAILIO_CPU_REQUEST="${KAMAILIO_CPU_REQUEST:-200m}"
KAMAILIO_MEMORY_REQUEST="${KAMAILIO_MEMORY_REQUEST:-256Mi}"
KAMAILIO_CPU_LIMIT="${KAMAILIO_CPU_LIMIT:-1000m}"
KAMAILIO_MEMORY_LIMIT="${KAMAILIO_MEMORY_LIMIT:-512Mi}"

DISPATCHER_CPU_REQUEST="${DISPATCHER_CPU_REQUEST:-50m}"
DISPATCHER_MEMORY_REQUEST="${DISPATCHER_MEMORY_REQUEST:-64Mi}"
DISPATCHER_CPU_LIMIT="${DISPATCHER_CPU_LIMIT:-200m}"
DISPATCHER_MEMORY_LIMIT="${DISPATCHER_MEMORY_LIMIT:-128Mi}"

# =============================================================================
# VALIDATION
# =============================================================================

echo "🔍 Validating Configuration"
echo "==========================="

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

echo "📋 Kamailio Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Environment: $ENVIRONMENT"
echo "   Namespace: $LIVEKIT_NAMESPACE"
echo "   SIP Port: $SIP_PORT"
echo ""

# Check if required tools are available
for tool in kubectl aws; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "❌ $tool is required but not installed"
        exit 1
    fi
    echo "✅ $tool: available"
done

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

# Verify cluster connectivity
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
echo "✅ Connected to cluster with $NODE_COUNT nodes"
echo ""

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Function to check if namespace exists
check_namespace() {
    local namespace="$1"
    
    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        echo "✅ Namespace '$namespace' exists"
        return 0
    else
        echo "❌ Namespace '$namespace' does not exist"
        return 1
    fi
}

# Function to cleanup on failure
cleanup_on_failure() {
    echo "🧹 Cleaning up failed Kamailio deployment..."
    
    # Delete deployment if it exists
    kubectl delete deployment kamailio -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    
    # Delete service if it exists
    kubectl delete service kamailio -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    
    # Delete configmap if it exists
    kubectl delete configmap kamailio-config -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    
    # Delete RBAC if it exists
    kubectl delete clusterrolebinding dispatchers-clusterrolebinding --ignore-not-found=true
    kubectl delete clusterrole dispatchers-clusterrole --ignore-not-found=true
    kubectl delete rolebinding dispatchers-rolebinding -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    kubectl delete role dispatchers-role -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    kubectl delete serviceaccount dispatchers -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    
    echo "✅ Cleanup completed"
}

# Function to wait for deployment to be ready
wait_for_deployment() {
    local deployment_name="$1"
    local namespace="$2"
    local timeout="${3:-300}"
    
    echo "⏳ Waiting for deployment '$deployment_name' to be ready (timeout: ${timeout}s)..."
    
    if kubectl wait --for=condition=available --timeout="${timeout}s" deployment/"$deployment_name" -n "$namespace"; then
        echo "✅ Deployment '$deployment_name' is ready"
        return 0
    else
        echo "❌ Deployment '$deployment_name' failed to become ready within ${timeout}s"
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo "🚀 Starting Kamailio Deployment Process"
echo "======================================="
echo ""

# -----------------------------------------------------------------------------
# STEP 1: VALIDATE PREREQUISITES
# -----------------------------------------------------------------------------

echo "📋 Step 1: Validate Prerequisites"
echo "================================="

echo "🔍 Checking if LiveKit namespace exists..."
if ! check_namespace "$LIVEKIT_NAMESPACE"; then
    echo "❌ LiveKit namespace does not exist. Please deploy LiveKit first."
    exit 1
fi

echo "🔍 Checking cluster connectivity..."
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Prerequisites validated"
echo ""

# -----------------------------------------------------------------------------
# STEP 2: CREATE KAMAILIO CONFIGMAP
# -----------------------------------------------------------------------------

echo "📋 Step 2: Create Kamailio ConfigMap"
echo "===================================="

echo "🔄 Creating Kamailio configuration..."

# Create the ConfigMap YAML
cat <<'EOF' > /tmp/kamailio-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kamailio-config
  namespace: livekit
data:
  kamailio.cfg: |
    #!KAMAILIO

    ####### Global Parameters #########
    debug=2
    log_stderror=yes
    log_facility=LOG_LOCAL0
    children=8

    tcp_connection_lifetime=3605
    tcp_max_connections=2048

    dns=no
    rev_dns=no

    server_header="Server: Kamailio LB"
    user_agent_header="User-Agent: Kamailio"

    listen=udp:0.0.0.0:5060
    listen=tcp:0.0.0.0:5060

    disable_tcp=no
    enable_sctp=no

    ####### Modules Section ########
    loadmodule "tm.so"
    loadmodule "tmx.so"
    loadmodule "sl.so"
    loadmodule "rr.so"
    loadmodule "pv.so"
    loadmodule "maxfwd.so"
    loadmodule "textops.so"
    loadmodule "siputils.so"
    loadmodule "xlog.so"
    loadmodule "sanity.so"
    loadmodule "dispatcher.so"
    loadmodule "ctl.so"

    ####### Module Parameters ########
    # RPC on TCP port 9998 (for dispatchers to connect)
    modparam("ctl", "binrpc", "tcp:127.0.0.1:9998")

    modparam("tm", "fr_timer", 30000)
    modparam("tm", "fr_inv_timer", 120000)

    modparam("rr", "enable_full_lr", 1)
    modparam("rr", "append_fromtag", 1)

    modparam("dispatcher", "list_file", "/etc/kamailio/dispatcher.list")
    modparam("dispatcher", "flags", 2)
    modparam("dispatcher", "ds_ping_method", "OPTIONS")
    modparam("dispatcher", "ds_ping_interval", 60)
    modparam("dispatcher", "ds_probing_mode", 1)
    modparam("dispatcher", "ds_ping_from", "sip:kamailio@localhost")

    ####### Routing Logic ########
    request_route {
      xlog("L_INFO", "[$rm] from $si:$sp -> $ru (CID: $ci)\n");
      
      if (!sanity_check()) {
        xlog("L_WARN", "Sanity check failed from $si\n");
        exit;
      }
      
      if (!mf_process_maxfwd_header("10")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
      }
      
      if (has_totag()) {
        if (loose_route()) {
          if (is_method("BYE")) {
            xlog("L_NOTICE", "BYE - Call ended (CID: $ci)\n");
          }
          route(RELAY);
          exit;
        } else {
          if (is_method("ACK")) {
            if (t_check_trans()) {
              route(RELAY);
              exit;
            }
          }
          sl_send_reply("404", "Not Found");
          exit;
        }
      }
      
      if (is_method("CANCEL")) {
        if (t_check_trans()) {
          route(RELAY);
        }
        exit;
      }
      
      if (is_method("INVITE|SUBSCRIBE")) {
        record_route();
      }
      
      if (is_method("INVITE")) {
        xlog("L_NOTICE", "NEW CALL: $fu -> $tu (CID: $ci)\n");
        
        if (!ds_select_dst("1", "4")) {
          xlog("L_ERR", "No backend available! Check dispatcher.list\n");
          send_reply("503", "Service Unavailable");
          exit;
        }
        
        xlog("L_NOTICE", "Routing to: $du\n");
        t_on_failure("BACKEND_FAIL");
        route(RELAY);
        exit;
      }
      
      if (is_method("OPTIONS")) {
        sl_send_reply("200", "OK");
        exit;
      }
      
      if (is_method("INFO|UPDATE|PRACK|REFER|NOTIFY|MESSAGE")) {
        xlog("L_INFO", "[$rm] relaying\n");
        route(RELAY);
        exit;
      }
      
      if (!ds_select_dst("1", "4")) {
        send_reply("503", "Service Unavailable");
        exit;
      }
      
      route(RELAY);
    }

    route[RELAY] {
      if (!t_relay()) {
        sl_reply_error();
      }
      exit;
    }

    failure_route[BACKEND_FAIL] {
      xlog("L_WARN", "Backend failed: $T_reply_code (CID: $ci)\n");
      
      if (t_is_canceled()) {
        exit;
      }
      
      if (ds_next_dst()) {
        xlog("L_NOTICE", "Failover to: $du\n");
        t_on_failure("BACKEND_FAIL");
        route(RELAY);
        exit;
      }
      
      xlog("L_ERR", "All backends failed (CID: $ci)\n");
    }

    onreply_route {
      if (status =~ "^(180|183)$") {
        xlog("L_INFO", "$rs Ringing (CID: $ci)\n");
      } else if (status =~ "^(200)$" && is_method("INVITE")) {
        xlog("L_NOTICE", "200 OK - Call connected (CID: $ci)\n");
      } else if (status =~ "^(4[0-9][0-9]|5[0-9][0-9])$") {
        xlog("L_WARN", "$rs $rr from $si\n");
      }
    }

    event_route[dispatcher:dst-down] {
      xlog("L_ERR", "Backend DOWN: $rm\n");
    }

    event_route[dispatcher:dst-up] {
      xlog("L_NOTICE", "Backend UP: $rm\n");
    }

EOF

echo "📄 Kamailio ConfigMap created at: /tmp/kamailio-configmap.yaml"

# Apply the ConfigMap
echo "🔄 Applying Kamailio ConfigMap..."
if kubectl apply -f /tmp/kamailio-configmap.yaml; then
    echo "✅ Kamailio ConfigMap applied successfully"
else
    echo "❌ Failed to apply Kamailio ConfigMap"
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 3: CREATE RBAC RESOURCES
# -----------------------------------------------------------------------------

echo "📋 Step 3: Create RBAC Resources"
echo "================================"

echo "🔄 Creating RBAC configuration..."

# Create the RBAC YAML
cat <<EOF > /tmp/kamailio-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dispatchers
  namespace: livekit
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dispatchers-clusterrole
rules:
  - apiGroups: [""]
    resources: 
      - "pods"
      - "pods/log"
      - "pods/status"
      - "services"
      - "endpoints"
      - "configmaps"
      - "secrets"
      - "persistentvolumeclaims"
      - "events"
      - "nodes"
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  - apiGroups: ["apps"]
    resources:
      - "deployments"
      - "deployments/scale"
      - "replicasets"
      - "replicasets/scale"
      - "statefulsets"
      - "statefulsets/scale"
      - "daemonsets"
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  - apiGroups: ["batch"]
    resources:
      - "jobs"
      - "cronjobs"
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  - apiGroups: ["networking.k8s.io"]
    resources:
      - "ingresses"
      - "networkpolicies"
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  - apiGroups: ["discovery.k8s.io"]
    resources:
      - "endpointslices"
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  - apiGroups: ["autoscaling"]
    resources:
      - "horizontalpodautoscalers"
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dispatchers-clusterrolebinding
subjects:
  - kind: ServiceAccount
    name: dispatchers
    namespace: livekit
roleRef:
  kind: ClusterRole
  name: dispatchers-clusterrole
  apiGroup: rbac.authorization.k8s.io
EOF

echo "📄 RBAC configuration created at: /tmp/kamailio-rbac.yaml"

# Apply the RBAC
echo "🔄 Applying RBAC configuration..."
if kubectl apply -f /tmp/kamailio-rbac.yaml; then
    echo "✅ RBAC configuration applied successfully"
else
    echo "❌ Failed to apply RBAC configuration"
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 4: CREATE KAMAILIO DEPLOYMENT
# -----------------------------------------------------------------------------

echo "📋 Step 4: Create Kamailio Deployment"
echo "====================================="

echo "🔄 Creating Kamailio deployment configuration..."

# Create the Deployment YAML
cat <<EOF > /tmp/kamailio-deployment.yaml
# ==========================================
# FIXED kamailio-deployment.yaml
# ==========================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kamailio
  namespace: livekit
  labels:
    app: kamailio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kamailio
  template:
    metadata:
      labels:
        app: kamailio
    spec:
      serviceAccountName: dispatchers

      volumes:
        - name: kamailio-config
          configMap:
            name: kamailio-config
        - name: dispatcher-shared
          emptyDir: {}

      initContainers:
        - name: init-dispatcher
          image: busybox:latest
          command:
            - sh
            - -c
            - |
              echo "# Dispatcher list - managed by dispatchers sidecar" > /etc/kamailio/dispatcher.list
              chmod 666 /etc/kamailio/dispatcher.list
              echo "Init complete"
          volumeMounts:
            - name: dispatcher-shared
              mountPath: /etc/kamailio

      containers:
        - name: dispatchers
          image: cycoresystems/dispatchers:latest

          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace

          args:
            - "-set"
            - "sip-server=1"
            - "-o"
            - "/etc/kamailio/dispatcher.list"
            - "-h"
            - "127.0.0.1"
            - "-p"
            - "9998"

          volumeMounts:
            - name: dispatcher-shared
              mountPath: /etc/kamailio

          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

        - name: kamailio
          image: ghcr.io/kamailio/kamailio:6.0.4-bookworm

          volumeMounts:
            - name: kamailio-config
              mountPath: /etc/kamailio/kamailio.cfg
              subPath: kamailio.cfg
            - name: dispatcher-shared
              mountPath: /etc/kamailio

          ports:
            - containerPort: 5060
              protocol: UDP
              name: sip-udp
            - containerPort: 5060
              protocol: TCP
              name: sip-tcp

          # FIXED: Use simple file check instead of ps command
          startupProbe:
            exec:
              command:
                - sh
                - -c
                - test -f /etc/kamailio/dispatcher.list && grep -q "^1 sip:" /etc/kamailio/dispatcher.list
            initialDelaySeconds: 10
            periodSeconds: 3
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 30

          # FIXED: Use TCP socket check
          readinessProbe:
            tcpSocket:
              port: 5060
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2

          # FIXED: Use TCP socket check
          livenessProbe:
            tcpSocket:
              port: 5060
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 2

          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi

EOF

echo "📄 Kamailio Deployment created at: /tmp/kamailio-deployment.yaml"

# Apply the Deployment
echo "🔄 Applying Kamailio Deployment..."
if kubectl apply -f /tmp/kamailio-deployment.yaml; then
    echo "✅ Kamailio Deployment applied successfully"
else
    echo "❌ Failed to apply Kamailio Deployment"
    cleanup_on_failure
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 5: CREATE KAMAILIO NLB SERVICE
# -----------------------------------------------------------------------------

echo "📋 Step 5: Create Kamailio NLB Service"
echo "======================================"

echo "🔄 Creating Kamailio NLB service configuration..."

# Create the Service YAML
cat <<EOF > /tmp/kamailio-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: kamailio
  namespace: livekit
  annotations:
    # NLB type
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    # Pod IPs as targets
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    # Internet-facing so Twilio can reach
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    # Optional: cross-zone balancing
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  selector:
    app: kamailio
  externalTrafficPolicy: Local   # preserves source IP
  ports:
    - name: sip-udp
      protocol: UDP
      port: 5060
      targetPort: 5060
    - name: sip-tcp
      protocol: TCP
      port: 5060
      targetPort: 5060
EOF

echo "📄 Kamailio NLB Service created at: /tmp/kamailio-service.yaml"

# Apply the Service
echo "🔄 Applying Kamailio NLB Service..."
if kubectl apply -f /tmp/kamailio-service.yaml; then
    echo "✅ Kamailio NLB Service applied successfully"
else
    echo "❌ Failed to apply Kamailio NLB Service"
    cleanup_on_failure
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 6: WAIT FOR DEPLOYMENT TO BE READY
# -----------------------------------------------------------------------------

echo "📋 Step 6: Wait for Deployment to be Ready"
echo "=========================================="

if wait_for_deployment "kamailio" "$LIVEKIT_NAMESPACE" 120; then
    echo "✅ Kamailio deployment is ready"
else
    echo "❌ Kamailio deployment failed to become ready"
    echo ""
    echo "🔍 Deployment status:"
    kubectl describe deployment kamailio -n "$LIVEKIT_NAMESPACE" || echo "Failed to get deployment status"
    echo ""
    echo "🔍 Pod status:"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=kamailio || echo "Failed to get pod status"
    echo ""
    cleanup_on_failure
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 7: VERIFY DEPLOYMENT
# -----------------------------------------------------------------------------

echo "📋 Step 7: Verify Deployment"
echo "============================"

echo "🔍 Checking Kamailio pods..."
PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=kamailio --no-headers 2>/dev/null | wc -l)
if [ "$PODS" -gt 0 ]; then
    echo "✅ Found $PODS Kamailio pod(s)"
    
    echo ""
    echo "📋 Pod Details:"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=kamailio -o wide
    echo ""
else
    echo "❌ No Kamailio pods found"
    cleanup_on_failure
    exit 1
fi

echo "🔍 Checking Kamailio NLB service..."
if kubectl get service kamailio -n "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Kamailio NLB service is running"
    
    echo ""
    echo "📋 Service Details:"
    kubectl get service kamailio -n "$LIVEKIT_NAMESPACE" -o wide
    echo ""
    
    echo "⏳ Waiting for NLB external IP (this may take a few minutes)..."
    for i in {1..30}; do
        EXTERNAL_IP=$(kubectl get service kamailio -n "$LIVEKIT_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [[ -n "$EXTERNAL_IP" ]]; then
            echo "✅ NLB External Hostname: $EXTERNAL_IP"
            break
        fi
        echo "⏳ Waiting for external IP... (attempt $i/30)"
        sleep 4
    done
    
    if [[ -z "$EXTERNAL_IP" ]]; then
        echo "⚠️  NLB external IP not yet available. Check AWS console for NLB status."
    fi
else
    echo "❌ Kamailio NLB service not found"
    cleanup_on_failure
    exit 1
fi

echo "🔍 Testing Kamailio connectivity and RBAC permissions..."
KAMAILIO_POD=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=kamailio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$KAMAILIO_POD" ]]; then
    echo "📋 Testing connectivity to Kamailio pod: $KAMAILIO_POD"
    
    # Test if the Kamailio process is running
    if kubectl exec -n "$LIVEKIT_NAMESPACE" "$KAMAILIO_POD" -c kamailio -- ps aux | grep -q kamailio; then
        echo "✅ Kamailio process is running in pod"
    else
        echo "⚠️  Kamailio process status unclear, but pod is running"
    fi
    
    # Check dispatcher list
    echo "🔍 Checking dispatcher list..."
    if kubectl exec -n "$LIVEKIT_NAMESPACE" "$KAMAILIO_POD" -c kamailio -- cat /etc/kamailio/dispatcher.list 2>/dev/null; then
        echo "✅ Dispatcher list is accessible"
    else
        echo "⚠️  Could not read dispatcher list"
    fi
    
    # Check dispatchers container logs for RBAC issues
    echo "🔍 Checking dispatchers container for RBAC issues..."
    DISPATCHER_LOGS=$(kubectl logs -n "$LIVEKIT_NAMESPACE" "$KAMAILIO_POD" -c dispatchers --tail=20 2>/dev/null || echo "")
    if echo "$DISPATCHER_LOGS" | grep -q "forbidden"; then
        echo "⚠️  RBAC permission issues detected in dispatchers logs:"
        echo "$DISPATCHER_LOGS" | grep "forbidden" | head -3
    else
        echo "✅ No RBAC permission issues detected in recent logs"
    fi
    
    # Test RBAC permissions directly
    echo "🔍 Testing RBAC permissions..."
    if kubectl auth can-i get pods --as=system:serviceaccount:$LIVEKIT_NAMESPACE:dispatchers -n "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
        echo "✅ ServiceAccount can access pods in namespace"
    else
        echo "⚠️  ServiceAccount cannot access pods in namespace"
    fi
    
    if kubectl auth can-i get endpointslices --as=system:serviceaccount:$LIVEKIT_NAMESPACE:dispatchers --all-namespaces >/dev/null 2>&1; then
        echo "✅ ServiceAccount can access endpointslices cluster-wide"
    else
        echo "⚠️  ServiceAccount cannot access endpointslices cluster-wide"
    fi
    
    # Check if SIP servers are being discovered
    echo "🔍 Checking SIP server discovery..."
    SIP_SERVERS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l sip-server=1 --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$SIP_SERVERS" -gt 0 ]; then
        echo "✅ Found $SIP_SERVERS SIP server pod(s) for load balancing"
        kubectl get pods -n "$LIVEKIT_NAMESPACE" -l sip-server=1 -o wide 2>/dev/null || echo "Could not list SIP servers"
    else
        echo "⚠️  No SIP server pods found with label sip-server=1"
    fi
else
    echo "⚠️  Could not find Kamailio pod for connectivity test"
fi

echo ""

# -----------------------------------------------------------------------------
# CLEANUP TEMPORARY FILES
# -----------------------------------------------------------------------------

echo "📋 Cleanup: Removing temporary files"
echo "===================================="

rm -f /tmp/kamailio-configmap.yaml /tmp/kamailio-rbac.yaml /tmp/kamailio-deployment.yaml /tmp/kamailio-service.yaml
echo "✅ Temporary files cleaned up"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "🎉 KAMAILIO DEPLOYMENT COMPLETE"
echo "==============================="
echo "✅ Kamailio ConfigMap created and applied"
echo "✅ RBAC resources created and applied"
echo "✅ Kamailio Deployment created and ready"
echo "✅ Kamailio NLB Service created and running"
echo "✅ Kamailio pods are healthy"
echo ""
echo "📋 Kamailio Summary:"
echo "   • Namespace: $LIVEKIT_NAMESPACE"
echo "   • SIP Port: $SIP_PORT"
echo "   • Environment: $ENVIRONMENT"
echo "   • Load Balancer: AWS NLB (internet-facing)"
echo ""
if [[ -n "${EXTERNAL_IP:-}" ]]; then
echo "📋 Access Information:"
echo "   📞 Kamailio SIP LB: $EXTERNAL_IP:$SIP_PORT"
echo "   🌐 External Hostname: $EXTERNAL_IP"
fi
echo ""
echo "📋 Next Steps:"
echo "   1. Kamailio is ready to load balance SIP calls"
echo "   2. Configure your SIP clients to connect via the NLB"
echo "   3. Monitor Kamailio logs: kubectl logs -n $LIVEKIT_NAMESPACE -l app=kamailio -c kamailio"
echo "   4. Monitor dispatcher logs: kubectl logs -n $LIVEKIT_NAMESPACE -l app=kamailio -c dispatchers"
echo "   5. Test SIP connectivity through the load balancer"
echo ""
echo "🔧 Troubleshooting:"
echo "   • RBAC Issues: Check dispatcher logs for 'forbidden' errors"
echo "   • No SIP Servers: Ensure SIP server pods have label 'sip-server=1'"
echo "   • Dispatcher List: kubectl exec -n $LIVEKIT_NAMESPACE <kamailio-pod> -c kamailio -- cat /etc/kamailio/dispatcher.list"
echo "   • Dispatcher Logs: kubectl logs -n $LIVEKIT_NAMESPACE <kamailio-pod> -c dispatchers"
echo "   • Dispatcher Args: kubectl describe pod -n $LIVEKIT_NAMESPACE <kamailio-pod> | grep -A 20 'dispatchers:'"
echo "   • RBAC Check: kubectl auth can-i get endpointslices --as=system:serviceaccount:$LIVEKIT_NAMESPACE:dispatchers --all-namespaces"
echo "   • Pod Status: kubectl describe pod -n $LIVEKIT_NAMESPACE -l app=kamailio"
echo "   • Service Status: kubectl get svc kamailio -n $LIVEKIT_NAMESPACE -o wide"
echo "   • NLB Status: Check AWS Console for Load Balancer health checks"
echo "   • SIP Server Discovery: kubectl get pods -n $LIVEKIT_NAMESPACE -l sip-server=1"
echo ""
echo "🔍 Health Checks:"
echo "   • Kamailio Process: kubectl exec -n $LIVEKIT_NAMESPACE <pod> -c kamailio -- ps aux | grep kamailio"
echo "   • SIP Port Test: kubectl exec -n $LIVEKIT_NAMESPACE <pod> -c kamailio -- netstat -tulpn | grep :5060"
echo "   • Dispatcher Connection: kubectl exec -n $LIVEKIT_NAMESPACE <pod> -c kamailio -- netstat -tulpn | grep :9998"
echo ""
echo "✅ Kamailio deployment completed at: $(date)"