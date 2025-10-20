package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/viper"
	"gopkg.in/yaml.v3"
)

// Loader handles configuration loading and merging
type Loader struct {
	configDirs []string
	envPrefix  string
}

// NewLoader creates a new configuration loader
func NewLoader() *Loader {
	// Find project root and set up config search paths
	configDirs := findConfigDirs()
	
	return &Loader{
		configDirs: configDirs,
		envPrefix:  "HOMELAB",
	}
}

// findConfigDirs locates configuration directories relative to project structure
func findConfigDirs() []string {
	// Get current working directory
	wd, err := os.Getwd()
	if err != nil {
		// Fallback to basic paths if we can't detect working directory
		return []string{"./configs", "../configs", os.Getenv("HOME") + "/.config/homelab", "/etc/homelab"}
	}

	var configDirs []string
	
	// Try to find project root
	projectRoot := findProjectRoot(wd)
	if projectRoot != "" {
		// Add project-relative config paths
		configDirs = append(configDirs, 
			filepath.Join(projectRoot, "bootstrap", "configs"),
			filepath.Join(projectRoot, "configs"),
		)
	}
	
	// Add working directory relative paths
	configDirs = append(configDirs, 
		".",
		"./configs", 
		"../configs",
		os.Getenv("HOME") + "/.config/homelab",
		"/etc/homelab",
	)
	
	return configDirs
}

// findProjectRoot finds the project root directory by looking for common project files
func findProjectRoot(startDir string) string {
	current := startDir
	for {
		// Check for project indicators
		indicators := []string{".git", "go.mod", "bootstrap", "Taskfile.yml"}
		for _, indicator := range indicators {
			if _, err := os.Stat(filepath.Join(current, indicator)); err == nil {
				return current
			}
		}
		
		// Move up one directory
		parent := filepath.Dir(current)
		if parent == current {
			// Reached filesystem root
			break
		}
		current = parent
	}
	
	return "" // Project root not found
}

// LoadConfig loads configuration from files and environment variables
func (l *Loader) LoadConfig(configType string) (*Config, error) {
	v := viper.New()

	// Set up Viper
	v.SetConfigName(configType) // homelab or nas
	v.SetConfigType("yaml")
	v.SetEnvPrefix(l.envPrefix)
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_", "-", "_"))
	v.AutomaticEnv()

	// Add config search paths
	for _, dir := range l.configDirs {
		v.AddConfigPath(dir)
	}

	// Set defaults
	l.setDefaults(v, configType)

	// Read config file
	if err := v.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); !ok {
			return nil, fmt.Errorf("failed to read config file: %w", err)
		}
		// Config file not found, use defaults and env vars
	}

	// Unmarshal into struct
	var config Config
	if err := v.Unmarshal(&config); err != nil {
		return nil, fmt.Errorf("failed to unmarshal config: %w", err)
	}

	// Load secrets from Vault if configured
	if err := l.loadSecrets(&config); err != nil {
		return nil, fmt.Errorf("failed to load secrets: %w", err)
	}

	// Resolve relative paths in configuration
	if err := l.resolveRelativePaths(&config); err != nil {
		return nil, fmt.Errorf("failed to resolve relative paths: %w", err)
	}

	// Debug: log the final GitOps configuration
	if config.NAS != nil {
		fmt.Printf("DEBUG: NAS GitOps config - Repository: %s, Branch: %s, Path: %s\n", 
			config.NAS.GitOps.Repository, config.NAS.GitOps.Branch, config.NAS.GitOps.Path)
	}
	if config.Homelab != nil {
		fmt.Printf("DEBUG: Homelab GitOps config - Repository: %s, Branch: %s, Path: %s\n", 
			config.Homelab.GitOps.Repository, config.Homelab.GitOps.Branch, config.Homelab.GitOps.Path)
	}

	// Validate configuration
	if err := l.validateConfig(&config); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	return &config, nil
}

// setDefaults sets default configuration values
func (l *Loader) setDefaults(v *viper.Viper, configType string) {
	// Common defaults
	v.SetDefault("gitops.provider", "fluxcd")
	v.SetDefault("gitops.branch", "main")

	if configType == "homelab" {
		// Homelab defaults
		v.SetDefault("homelab.cluster.distribution", "talos")
		v.SetDefault("homelab.cluster.cni", "cilium")
		v.SetDefault("homelab.cluster.version", "v1.29.0")
		v.SetDefault("homelab.cluster.networking.pod_cidr", "10.244.0.0/16")
		v.SetDefault("homelab.cluster.networking.service_cidr", "10.96.0.0/12")
		v.SetDefault("homelab.cluster.networking.cluster_dns", "10.96.0.10")
		v.SetDefault("homelab.storage.provider", "rook-ceph")
		v.SetDefault("homelab.storage.replicas", 3)
		v.SetDefault("homelab.networking.service_mesh.provider", "istio")
		v.SetDefault("homelab.networking.ingress.provider", "nginx")
		v.SetDefault("homelab.security.vault.transit_path", "transit")
		v.SetDefault("homelab.security.vault.pki_path", "pki")
		v.SetDefault("homelab.monitoring.prometheus.retention", "30d")
		v.SetDefault("homelab.monitoring.grafana.admin_user", "admin")

		// Timeouts
		v.SetDefault("homelab.cluster.timeouts.bootstrap", "10m")
		v.SetDefault("homelab.cluster.timeouts.infrastructure", "15m")
		v.SetDefault("homelab.cluster.timeouts.application", "10m")
		v.SetDefault("homelab.cluster.timeouts.validation", "5m")
	} else if configType == "nas" {
		// NAS defaults
		v.SetDefault("nas.cluster.host", "192.168.1.20")
		v.SetDefault("nas.cluster.port", 2376)
		v.SetDefault("nas.cluster.docker_host", "tcp://192.168.1.20:2376")
		v.SetDefault("nas.cluster.cert_path", "../infrastructure/nas/cert")
		v.SetDefault("nas.storage.minio.enabled", true)
		v.SetDefault("nas.storage.minio.root_user", "admin")
		v.SetDefault("nas.security.vault.address", "http://192.168.1.42:61200")
		v.SetDefault("nas.security.vault.transit_path", "transit")

		// Timeouts
		v.SetDefault("nas.cluster.timeouts.bootstrap", "5m")
		v.SetDefault("nas.cluster.timeouts.infrastructure", "10m")
		v.SetDefault("nas.cluster.timeouts.application", "5m")
		v.SetDefault("nas.cluster.timeouts.validation", "3m")
	}
}

// loadSecrets loads sensitive values from Vault or environment
func (l *Loader) loadSecrets(config *Config) error {
	// Load GitHub token from environment
	if githubToken := os.Getenv("GITHUB_TOKEN"); githubToken != "" {
		if config.Homelab != nil {
			config.Homelab.GitOps.Token = githubToken
		}
		if config.NAS != nil {
			config.NAS.GitOps.Token = githubToken
		}
	}

	// Load Vault token from environment
	if vaultToken := os.Getenv("VAULT_TOKEN"); vaultToken != "" {
		if config.Homelab != nil {
			config.Homelab.Integration.Vault.Token = vaultToken
		}
		if config.NAS != nil {
			config.NAS.Integration.Vault.Token = vaultToken
		}
	}

	// Load AWS credentials from environment
	if config.Homelab != nil || config.NAS != nil {
		if accessKey := os.Getenv("AWS_ACCESS_KEY_ID"); accessKey != "" {
			if secretKey := os.Getenv("AWS_SECRET_ACCESS_KEY"); secretKey != "" {
				if config.Homelab != nil {
					config.Homelab.Integration.AWS.AccessKey = accessKey
					config.Homelab.Integration.AWS.SecretKey = secretKey
				}
				if config.NAS != nil {
					config.NAS.Integration.AWS.AccessKey = accessKey
					config.NAS.Integration.AWS.SecretKey = secretKey
				}
			}
		}
	}

	return nil
}

// validateConfig validates the loaded configuration
func (l *Loader) validateConfig(config *Config) error {
	// Basic validation - in a real implementation, use a validation library
	if config.Homelab != nil {
		if config.Homelab.Cluster.Name == "" {
			return fmt.Errorf("homelab cluster name is required")
		}
		if len(config.Homelab.Cluster.Nodes) == 0 {
			return fmt.Errorf("homelab cluster nodes are required")
		}
		if config.Homelab.GitOps.Repository == "" {
			return fmt.Errorf("homelab gitops repository is required")
		}
	}

	if config.NAS != nil {
		if config.NAS.Cluster.Name == "" {
			return fmt.Errorf("nas cluster name is required")
		}
		if config.NAS.Cluster.Host == "" {
			return fmt.Errorf("nas cluster host is required")
		}
		if config.NAS.GitOps.Repository == "" {
			return fmt.Errorf("nas gitops repository is required")
		}
	}

	return nil
}

// SaveConfig saves configuration to a file
func (l *Loader) SaveConfig(config *Config, filename string) error {
	data, err := yaml.Marshal(config)
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(filename), 0755); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	if err := os.WriteFile(filename, data, 0644); err != nil {
		return fmt.Errorf("failed to write config file: %w", err)
	}

	return nil
}

// GetConfigPaths returns the paths where configuration files are searched
func (l *Loader) GetConfigPaths() []string {
	return l.configDirs
}

// resolveRelativePaths resolves relative paths in configuration to absolute paths
func (l *Loader) resolveRelativePaths(config *Config) error {
	// Find project root for resolving relative paths
	projectRoot := findProjectRoot(os.Getenv("PWD"))
	if projectRoot == "" {
		// Fall back to current working directory
		wd, err := os.Getwd()
		if err != nil {
			return fmt.Errorf("failed to get working directory: %w", err)
		}
		projectRoot = wd
	}

	// Resolve NAS cluster kubeconfig path
	if config.NAS != nil && config.NAS.Cluster.KubeConfig != "" {
		if !filepath.IsAbs(config.NAS.Cluster.KubeConfig) {
			config.NAS.Cluster.KubeConfig = filepath.Join(projectRoot, config.NAS.Cluster.KubeConfig)
		}
	}

	// Resolve Homelab cluster kubeconfig path
	if config.Homelab != nil && config.Homelab.Cluster.KubeConfig != "" {
		if !filepath.IsAbs(config.Homelab.Cluster.KubeConfig) {
			config.Homelab.Cluster.KubeConfig = filepath.Join(projectRoot, config.Homelab.Cluster.KubeConfig)
		}
	}

	// Resolve NAS cert path
	if config.NAS != nil && config.NAS.Cluster.CertPath != "" {
		if !filepath.IsAbs(config.NAS.Cluster.CertPath) {
			config.NAS.Cluster.CertPath = filepath.Join(projectRoot, config.NAS.Cluster.CertPath)
		}
	}

	return nil
}
