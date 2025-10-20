# 🚀 Homelab Bootstrap Tool

A modern, unified command-line tool for bootstrapping and managing homelab and NAS Kubernetes clusters using GitOps practices.

## ✨ Features

### 🏠 Homelab Clusters
- **Talos Linux** with enterprise-grade security
- **Cilium CNI** with advanced networking and observability
- **FluxCD GitOps** for declarative cluster management
- **Vault integration** for secrets management
- **Cross-cluster service mesh** with Istio

### 💾 NAS Clusters
- **K3s** lightweight Kubernetes distribution
- **MinIO** for S3-compatible object storage
- **FluxCD GitOps** for consistent operations
- **Backup integration** with Velero

### 🔧 Platform Engineering Features
- **Comprehensive health checks** for all cluster components
- **Security validation** with CIS/NIST/SOC2 compliance
- **Resource management** with autoscaling validation
- **Observability stack** validation (Prometheus, Grafana, Jaeger)
- **Backup and disaster recovery** validation
- **Beautiful interactive TUI** with real-time progress
- **Structured logging** with Charmbracelet log

## 🚀 Quick Start

### Installation
```bash
# Clone and build
git clone <repository>
cd bootstrap
go build -o bootstrap ./cmd/bootstrap/main.go
```

### Deploy Everything
```bash
# Deploy both NAS and homelab clusters
./bootstrap deploy all

# Or deploy individually
./bootstrap deploy homelab
./bootstrap deploy nas
```

### Step-by-Step Deployment
```bash
# Check prerequisites
./bootstrap homelab check
./bootstrap nas check

# Bootstrap clusters
./bootstrap homelab bootstrap --no-tui
./bootstrap nas bootstrap --no-tui

# Validate deployments
./bootstrap homelab validate
./bootstrap nas validate
```

## 📋 Commands

### Global Commands
```bash
./bootstrap --help                    # Show all commands
./bootstrap version                   # Show version info
./bootstrap --verbose                 # Enable verbose logging
./bootstrap --debug                   # Enable debug logging
```

### Homelab Operations
```bash
./bootstrap homelab bootstrap         # Interactive bootstrap
./bootstrap homelab bootstrap --no-tui # Non-interactive bootstrap
./bootstrap homelab check             # Check prerequisites
./bootstrap homelab install           # Install infrastructure
./bootstrap homelab validate          # Validate deployment
./bootstrap homelab destroy           # Destroy cluster
```

### NAS Operations
```bash
./bootstrap nas bootstrap             # Interactive bootstrap
./bootstrap nas bootstrap --no-tui    # Non-interactive bootstrap
./bootstrap nas check                 # Check prerequisites
./bootstrap nas install               # Install infrastructure
./bootstrap nas validate              # Validate deployment
./bootstrap nas destroy               # Destroy cluster
```

### Quick Deploy Commands
```bash
./bootstrap deploy homelab            # Quick homelab deployment
./bootstrap deploy nas                # Quick NAS deployment
./bootstrap deploy all                # Deploy both clusters
```

### Operational Commands
```bash
./bootstrap force-cleanup-namespaces  # Force cleanup stuck namespaces
./bootstrap recovery diagnose         # Diagnose system issues
```

## 🔧 Configuration

Configuration files are located in `configs/`:
- `homelab.yaml` - Homelab cluster configuration
- `nas.yaml` - NAS cluster configuration

### Environment Variables
```bash
# Vault configuration
VAULT_TRANSIT_TOKEN=<your-transit-token>

# Cluster configuration
KUBECONFIG=./kubeconfig
NAS_KUBECONFIG=./infrastructure/nas/kubeconfig.yaml
```

## 🏗️ Architecture

### Project Structure
```
bootstrap/
├── cmd/bootstrap/          # Unified CLI entrypoint
├── internal/
│   ├── homelab/           # Homelab-specific commands
│   └── nas/               # NAS-specific commands
├── pkg/
│   ├── backup/            # Backup system validation
│   ├── bootstrap/         # Core orchestration logic
│   ├── config/            # Configuration management
│   ├── flux/              # FluxCD integration
│   ├── health/            # Comprehensive health checks
│   ├── infra/             # Infrastructure components
│   ├── k8s/               # Kubernetes client wrapper
│   ├── observability/     # Monitoring stack validation
│   ├── resources/         # Resource management validation
│   ├── secrets/           # Secret management
│   ├── security/          # Security posture validation
│   └── tui/               # Interactive terminal UI
├── configs/               # Configuration files
└── scripts/               # Legacy bash scripts (reference)
```

### Key Components

#### 🎛️ Bootstrap Orchestrator
Central coordinator that manages the complete bootstrap process:
- Cluster verification and connectivity
- CNI installation (Cilium for homelab)
- FluxCD installation and GitOps bootstrap
- Secret management (cluster-vars, vault tokens)
- Cross-cluster setup (Istio remote secrets)
- Infrastructure readiness validation

#### 🏥 Health Validation Suite
Comprehensive platform validation covering:
- **API Server**: Latency and responsiveness checks
- **Nodes**: Health, capacity, and pressure monitoring
- **Networking**: CNI, DNS, and connectivity validation
- **Storage**: Storage classes and persistent volume checks
- **Control Plane**: Component health and availability

#### 🔒 Security Validation
Enterprise-grade security posture validation:
- **Pod Security Standards** compliance
- **Network Policies** enforcement
- **RBAC** configuration and least-privilege validation
- **Admission Controllers** detection
- **Compliance** frameworks (CIS, NIST, SOC2)

#### 📊 Observability Validation
Monitoring and observability stack health:
- **Prometheus/Grafana** health and configuration
- **AlertManager** and active alert monitoring
- **Jaeger** distributed tracing validation
- **Logging** stack health (Loki/ELK/Fluent Bit)
- **Service Mesh** observability (Istio telemetry)

#### 💾 Backup & Disaster Recovery
Backup system validation and testing:
- **Velero** installation and configuration
- **etcd** backup validation (Talos-aware)
- **Storage** connectivity and retention policies
- **Restore** capability testing

## 🎨 User Experience

### Interactive TUI Mode
```bash
./bootstrap homelab bootstrap
```
Features beautiful real-time progress with:
- Step-by-step progress indicators
- Real-time log streaming
- Error highlighting with remediation suggestions
- Estimated completion times

### Non-Interactive Mode
```bash
./bootstrap homelab bootstrap --no-tui
```
Perfect for CI/CD with:
- Structured JSON logging
- Exit codes for automation
- Detailed error reporting
- Progress metrics

## 🔍 Troubleshooting

### Common Issues

**Cluster Not Ready**
```bash
./bootstrap homelab check    # Validate prerequisites
kubectl get nodes            # Check node status
kubectl get pods -A          # Check pod status
```

**FluxCD Issues**
```bash
./bootstrap homelab validate # Check GitOps status
flux get kustomizations      # Check flux sync status
flux logs                    # Check flux logs
```

**Network Issues**
```bash
kubectl get networkpolicies -A        # Check network policies
kubectl get svc istio-eastwestgateway # Check service mesh
```

### Debug Mode
```bash
./bootstrap --debug homelab bootstrap --no-tui
```

## 🤝 Contributing

This tool follows modern Go and platform engineering best practices:
- Clean architecture with clear separation of concerns
- Comprehensive error handling and validation
- Beautiful user experience with structured logging
- Production-ready with enterprise platform features

## 📝 Migration from Bash Scripts

This Go implementation completely replaces the original bash scripts while providing:
- ✅ **100% feature parity** with original functionality including destroy and recovery
- 🚀 **Enhanced capabilities** with comprehensive validation and diagnostics
- 🎨 **Better UX** with interactive TUI and structured logging
- 🔒 **Enterprise features** for production platform deployment
- 🏗️ **Maintainable architecture** for long-term platform evolution
- 🔧 **Operational tools** for disaster recovery and troubleshooting

### Key Improvements Over Bash Scripts

**Destroy Functionality:**
- Comprehensive FluxCD resource cleanup with proper suspension
- Rook-Ceph cleanup with finalizer management
- Aggressive namespace cleanup for stuck resources
- PersistentVolume and CRD cleanup
- Force finalization via Kubernetes API

**Recovery & Diagnostics:**
- System health diagnostics for both clusters
- Component-level status checking (API server, nodes, FluxCD, Istio)
- Structured diagnostic reporting with recovery recommendations
- Automated troubleshooting guidance

**Enhanced Operations:**
- Unified command interface with consistent UX
- Enterprise-grade logging and error handling
- Cross-platform compatibility and better maintainability

The original bash scripts in `scripts/` are kept for reference but are no longer used.