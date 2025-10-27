package config

// Config represents the main configuration structure
type Config struct {
	Homelab *HomelabConfig `yaml:"homelab,omitempty"`
	NAS     *NASConfig     `yaml:"nas,omitempty"`
}

// HomelabConfig represents homelab-specific configuration
type HomelabConfig struct {
	Cluster        ClusterConfig         `yaml:"cluster"`
	Infrastructure *InfrastructureConfig `yaml:"infrastructure,omitempty"`
	Storage        StorageConfig         `yaml:"storage"`
	GitOps         GitOpsConfig          `yaml:"gitops"`
	Networking     NetworkingConfig      `yaml:"networking"`
	Security       SecurityConfig        `yaml:"security"`
	Monitoring     MonitoringConfig      `yaml:"monitoring"`
	Integration    IntegrationConfig     `yaml:"integration"`
}

// InfrastructureConfig represents infrastructure provisioning configuration
type InfrastructureConfig struct {
	TerraformDir string `yaml:"terraform_dir,omitempty"`
	PodCIDR      string `yaml:"pod_cidr,omitempty"`
	ServiceCIDR  string `yaml:"service_cidr,omitempty"`
	Provider     string `yaml:"provider,omitempty"` // proxmox, aws, etc
}

// NASConfig represents NAS-specific configuration
type NASConfig struct {
	Cluster        NASClusterConfig         `yaml:"cluster"`
	Infrastructure *NASInfrastructureConfig `yaml:"infrastructure,omitempty"`
	Storage        NASStorageConfig         `yaml:"storage"`
	GitOps         GitOpsConfig             `yaml:"gitops"`
	Security       SecurityConfig           `yaml:"security"`
	Integration    IntegrationConfig        `yaml:"integration"`
}

// NASInfrastructureConfig represents NAS infrastructure configuration
type NASInfrastructureConfig struct {
	ComposeDir string `yaml:"compose_dir,omitempty"`
	DockerHost string `yaml:"docker_host,omitempty"`
	CertPath   string `yaml:"cert_path,omitempty"`
}

// ClusterConfig represents Kubernetes cluster configuration
type ClusterConfig struct {
	Name         string            `yaml:"name" validate:"required"`
	Nodes        []string          `yaml:"nodes" validate:"required,min=1"`
	CNI          string            `yaml:"cni" validate:"required,oneof=cilium calico flannel"`
	KubeConfig   string            `yaml:"kubeconfig" validate:"required"`
	Distribution string            `yaml:"distribution" validate:"required,oneof=talos k3s"`
	Version      string            `yaml:"version"`
	Timeouts     TimeoutConfig     `yaml:"timeouts"`
	Networking   ClusterNetworking `yaml:"networking"`
}

// NASClusterConfig represents NAS-specific cluster config
type NASClusterConfig struct {
	Name       string        `yaml:"name" validate:"required"`
	Host       string        `yaml:"host" validate:"required,ip"`
	Port       int           `yaml:"port" validate:"required,min=1,max=65535"`
	DockerHost string        `yaml:"docker_host" validate:"required"`
	CertPath   string        `yaml:"cert_path" validate:"required,dir"`
	KubeConfig string        `yaml:"kubeconfig" validate:"required"`
	Timeouts   TimeoutConfig `yaml:"timeouts"`
}

// StorageConfig represents storage configuration
type StorageConfig struct {
	Provider string            `yaml:"provider" validate:"required,oneof=ceph local-path none"`
	Replicas int               `yaml:"replicas" validate:"required,min=1"`
	Size     string            `yaml:"size" validate:"required"`
	Options  map[string]string `yaml:"options,omitempty"`
}

// NASStorageConfig represents NAS-specific storage
type NASStorageConfig struct {
	Provider string      `yaml:"provider" validate:"required,oneof=ceph local-path none"`
	MinIO    MinIOConfig `yaml:"minio"`
}

// MinIOConfig represents MinIO configuration
type MinIOConfig struct {
	Enabled      bool              `yaml:"enabled"`
	RootUser     string            `yaml:"root_user" validate:"required"`
	RootPassword string            `yaml:"root_password,omitempty"` // Will be fetched from Vault
	Buckets      []string          `yaml:"buckets"`
	Options      map[string]string `yaml:"options,omitempty"`
}

// GitOpsConfig represents GitOps configuration
type GitOpsConfig struct {
	Provider   string `yaml:"provider" validate:"required,oneof=fluxcd argocd"`
	Repository string `yaml:"repository" validate:"required,url"`
	Branch     string `yaml:"branch" validate:"required"`
	Path       string `yaml:"path" validate:"required"`
	Owner      string `yaml:"owner" validate:"required"`
	Token      string `yaml:"token,omitempty"` // Will be fetched from env
}

// NetworkingConfig represents networking configuration
type NetworkingConfig struct {
	ServiceMesh ServiceMeshConfig `yaml:"service_mesh"`
	Ingress     IngressConfig     `yaml:"ingress"`
	DNS         DNSConfig         `yaml:"dns"`
}

// ClusterNetworking represents cluster-level networking
type ClusterNetworking struct {
	PodCIDR     string `yaml:"pod_cidr" validate:"required,cidr"`
	ServiceCIDR string `yaml:"service_cidr" validate:"required,cidr"`
	ClusterDNS  string `yaml:"cluster_dns" validate:"required,ip"`
}

// ServiceMeshConfig represents service mesh configuration
type ServiceMeshConfig struct {
	Enabled  bool   `yaml:"enabled"`
	Provider string `yaml:"provider" validate:"oneof=istio linkerd consul"`
	Version  string `yaml:"version"`
}

// IngressConfig represents ingress configuration
type IngressConfig struct {
	Provider string `yaml:"provider" validate:"oneof=nginx traefik istio"`
	Class    string `yaml:"class"`
	TLS      bool   `yaml:"tls"`
}

// DNSConfig represents DNS configuration
type DNSConfig struct {
	Provider   string   `yaml:"provider" validate:"oneof=coredns external-dns"`
	Domains    []string `yaml:"domains"`
	Nameserver string   `yaml:"nameserver,omitempty"`
}

// SecurityConfig represents security configuration
type SecurityConfig struct {
	TLS         TLSConfig         `yaml:"tls"`
	RBAC        RBACConfig        `yaml:"rbac"`
	Policies    bool              `yaml:"policies"`
	Vault       VaultConfig       `yaml:"vault"`
	CertManager CertManagerConfig `yaml:"cert_manager"`
}

// TLSConfig represents TLS configuration
type TLSConfig struct {
	Enabled bool   `yaml:"enabled"`
	CA      string `yaml:"ca,omitempty"`
	Cert    string `yaml:"cert,omitempty"`
	Key     string `yaml:"key,omitempty"`
}

// RBACConfig represents RBAC configuration
type RBACConfig struct {
	Enabled bool     `yaml:"enabled"`
	Roles   []string `yaml:"roles,omitempty"`
}

// VaultConfig represents Vault configuration
type VaultConfig struct {
	Enabled     bool   `yaml:"enabled"`
	Address     string `yaml:"address" validate:"required_if=Enabled true,url"`
	Token       string `yaml:"token,omitempty"`
	TransitPath string `yaml:"transit_path" validate:"required_if=Enabled true"`
	PKIPath     string `yaml:"pki_path,omitempty"`
}

// CertManagerConfig represents cert-manager configuration
type CertManagerConfig struct {
	Enabled bool              `yaml:"enabled"`
	Issuers []IssuerConfig    `yaml:"issuers"`
	Options map[string]string `yaml:"options,omitempty"`
}

// IssuerConfig represents certificate issuer configuration
type IssuerConfig struct {
	Name    string            `yaml:"name" validate:"required"`
	Type    string            `yaml:"type" validate:"required,oneof=letsencrypt selfsigned ca"`
	Email   string            `yaml:"email,omitempty"`
	Server  string            `yaml:"server,omitempty"`
	Options map[string]string `yaml:"options,omitempty"`
}

// MonitoringConfig represents monitoring configuration
type MonitoringConfig struct {
	Prometheus PrometheusConfig `yaml:"prometheus"`
	Grafana    GrafanaConfig    `yaml:"grafana"`
	Alerting   AlertingConfig   `yaml:"alerting"`
}

// PrometheusConfig represents Prometheus configuration
type PrometheusConfig struct {
	Enabled   bool              `yaml:"enabled"`
	Retention string            `yaml:"retention" validate:"required_if=Enabled true"`
	Storage   string            `yaml:"storage" validate:"required_if=Enabled true"`
	Options   map[string]string `yaml:"options,omitempty"`
}

// GrafanaConfig represents Grafana configuration
type GrafanaConfig struct {
	Enabled    bool              `yaml:"enabled"`
	AdminUser  string            `yaml:"admin_user" validate:"required_if=Enabled true"`
	AdminPass  string            `yaml:"admin_pass,omitempty"`
	Dashboards []string          `yaml:"dashboards,omitempty"`
	Options    map[string]string `yaml:"options,omitempty"`
}

// AlertingConfig represents alerting configuration
type AlertingConfig struct {
	Enabled  bool              `yaml:"enabled"`
	Webhook  string            `yaml:"webhook,omitempty"`
	Channels []string          `yaml:"channels,omitempty"`
	Options  map[string]string `yaml:"options,omitempty"`
}

// IntegrationConfig represents external integration configuration
type IntegrationConfig struct {
	Vault VaultConfig `yaml:"vault"`
	AWS   AWSConfig   `yaml:"aws"`
	OVH   OVHConfig   `yaml:"ovh"`
}

// AWSConfig represents AWS integration configuration
type AWSConfig struct {
	Enabled   bool   `yaml:"enabled"`
	AccessKey string `yaml:"access_key,omitempty"`
	SecretKey string `yaml:"secret_key,omitempty"`
	Region    string `yaml:"region" validate:"required_if=Enabled true"`
	S3Bucket  string `yaml:"s3_bucket,omitempty"`
}

// OVHConfig represents OVH integration configuration
type OVHConfig struct {
	Enabled           bool   `yaml:"enabled"`
	ApplicationKey    string `yaml:"application_key,omitempty"`
	ApplicationSecret string `yaml:"application_secret,omitempty"`
	ConsumerKey       string `yaml:"consumer_key,omitempty"`
	Endpoint          string `yaml:"endpoint" validate:"required_if=Enabled true"`
}

// TimeoutConfig represents timeout configuration
type TimeoutConfig struct {
	Bootstrap      string `yaml:"bootstrap" validate:"required"`
	Infrastructure string `yaml:"infrastructure" validate:"required"`
	Application    string `yaml:"application" validate:"required"`
	Validation     string `yaml:"validation" validate:"required"`
}
