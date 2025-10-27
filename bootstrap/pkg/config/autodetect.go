package config

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/log"
)

// AutoDetector automatically detects environment configuration
type AutoDetector struct {
	projectRoot string
}

// NewAutoDetector creates a new auto detector
func NewAutoDetector(projectRoot string) *AutoDetector {
	return &AutoDetector{
		projectRoot: projectRoot,
	}
}

// DetectAndSetDefaults detects environment and sets default values
func (ad *AutoDetector) DetectAndSetDefaults() error {
	log.Info("Auto-detecting environment configuration")
	
	// Detect network configuration
	if err := ad.detectNetwork(); err != nil {
		log.Warn("Failed to auto-detect network", "error", err)
	}
	
	// Detect cluster IPs
	if err := ad.detectClusterIPs(); err != nil {
		log.Warn("Failed to auto-detect cluster IPs", "error", err)
	}
	
	// Detect domain
	if err := ad.detectDomain(); err != nil {
		log.Warn("Failed to auto-detect domain", "error", err)
	}
	
	// Detect paths
	ad.detectPaths()
	
	// Set default values if not already set
	ad.setDefaults()
	
	return nil
}

// detectNetwork detects the local network configuration
func (ad *AutoDetector) detectNetwork() error {
	localIP := ad.getLocalIP()
	if localIP == "" {
		return fmt.Errorf("unable to detect local IP")
	}
	
	parts := strings.Split(localIP, ".")
	if len(parts) != 4 {
		return fmt.Errorf("invalid IP format")
	}
	
	// Set network prefix for other detections
	networkPrefix := fmt.Sprintf("%s.%s.%s", parts[0], parts[1], parts[2])
	
	// Set default IPs based on common patterns
	if os.Getenv("CONTROL_PLANE_IP") == "" {
		os.Setenv("CONTROL_PLANE_IP", fmt.Sprintf("%s.67", networkPrefix))
		log.Debug("Auto-detected control plane IP", "ip", os.Getenv("CONTROL_PLANE_IP"))
	}
	
	if os.Getenv("ARGO_CONTROL_PLANE_IP") == "" {
		os.Setenv("ARGO_CONTROL_PLANE_IP", os.Getenv("CONTROL_PLANE_IP"))
	}
	
	if os.Getenv("NAS_IP") == "" {
		os.Setenv("NAS_IP", fmt.Sprintf("%s.42", networkPrefix))
		log.Debug("Auto-detected NAS IP", "ip", os.Getenv("NAS_IP"))
	}
	
	if os.Getenv("WORKER1_IP") == "" {
		os.Setenv("WORKER1_IP", fmt.Sprintf("%s.68", networkPrefix))
	}
	
	if os.Getenv("WORKER2_IP") == "" {
		os.Setenv("WORKER2_IP", fmt.Sprintf("%s.69", networkPrefix))
	}
	
	return nil
}

// detectClusterIPs detects gateway IPs
func (ad *AutoDetector) detectClusterIPs() error {
	// Gateway addresses
	if os.Getenv("HOMELAB_EW_GATEWAY_ADDR") == "" && os.Getenv("CONTROL_PLANE_IP") != "" {
		os.Setenv("HOMELAB_EW_GATEWAY_ADDR", os.Getenv("CONTROL_PLANE_IP"))
		log.Debug("Set homelab gateway address from control plane IP")
	}
	
	if os.Getenv("NAS_EW_GATEWAY_ADDR") == "" && os.Getenv("NAS_IP") != "" {
		os.Setenv("NAS_EW_GATEWAY_ADDR", os.Getenv("NAS_IP"))
		log.Debug("Set NAS gateway address from NAS IP")
	}
	
	// Default ports
	if os.Getenv("HOMELAB_EW_GATEWAY_PORT") == "" {
		os.Setenv("HOMELAB_EW_GATEWAY_PORT", "15443")
	}
	
	if os.Getenv("NAS_EW_GATEWAY_PORT") == "" {
		os.Setenv("NAS_EW_GATEWAY_PORT", "15443")
	}
	
	// Vault addresses
	if os.Getenv("QNAP_VAULT_ADDR") == "" && os.Getenv("NAS_IP") != "" {
		os.Setenv("QNAP_VAULT_ADDR", fmt.Sprintf("http://%s:61200", os.Getenv("NAS_IP")))
		log.Debug("Set QNAP Vault address", "addr", os.Getenv("QNAP_VAULT_ADDR"))
	}
	
	if os.Getenv("ARGO_NAS_VAULT_ADDR") == "" {
		os.Setenv("ARGO_NAS_VAULT_ADDR", os.Getenv("QNAP_VAULT_ADDR"))
	}
	
	return nil
}

// detectDomain tries to detect the domain
func (ad *AutoDetector) detectDomain() error {
	// Try hostname-based detection
	hostname, err := os.Hostname()
	if err == nil {
		parts := strings.Split(hostname, ".")
		if len(parts) > 2 {
			// Extract domain from FQDN
			domain := strings.Join(parts[1:], ".")
			if os.Getenv("EXTERNAL_DOMAIN") == "" {
				os.Setenv("EXTERNAL_DOMAIN", domain)
				log.Debug("Auto-detected domain from hostname", "domain", domain)
			}
			if os.Getenv("ARGO_EXTERNAL_DOMAIN") == "" {
				os.Setenv("ARGO_EXTERNAL_DOMAIN", domain)
			}
			return nil
		}
	}
	
	// Default to example domain if nothing found
	if os.Getenv("EXTERNAL_DOMAIN") == "" {
		os.Setenv("EXTERNAL_DOMAIN", "homelab.local")
		log.Debug("Using default domain", "domain", "homelab.local")
	}
	
	return nil
}

// detectPaths detects common paths
func (ad *AutoDetector) detectPaths() {
	// Kubeconfig paths
	if os.Getenv("HOMELAB_KUBECONFIG_PATH") == "" {
		defaultPath := filepath.Join(ad.projectRoot, "kubeconfig")
		if _, err := os.Stat(defaultPath); err == nil {
			os.Setenv("HOMELAB_KUBECONFIG_PATH", defaultPath)
			log.Debug("Found homelab kubeconfig", "path", defaultPath)
		}
	}
	
	if os.Getenv("NAS_KUBECONFIG_PATH") == "" {
		paths := []string{
			filepath.Join(ad.projectRoot, "infrastructure/nas/kubeconfig.yaml"),
			filepath.Join(ad.projectRoot, "infrastructure/nas/kubeconfig"),
		}
		for _, path := range paths {
			if _, err := os.Stat(path); err == nil {
				os.Setenv("NAS_KUBECONFIG_PATH", path)
				log.Debug("Found NAS kubeconfig", "path", path)
				break
			}
		}
	}
	
	// CA certs directory
	if os.Getenv("CACERTS_DIR") == "" {
		defaultPath := filepath.Join(ad.projectRoot, "cacerts")
		if stat, err := os.Stat(defaultPath); err == nil && stat.IsDir() {
			os.Setenv("CACERTS_DIR", defaultPath)
			log.Debug("Found CA certs directory", "path", defaultPath)
		}
	}
}

// setDefaults sets default values for common variables
func (ad *AutoDetector) setDefaults() {
	defaults := map[string]string{
		"ISTIO_VERSION": "1.24.0",
		"ISTIO_HELM_REPO": "https://istio-release.storage.googleapis.com/charts",
		"ISTIO_REVISION": "default",
		"NETWORK_HOMELAB": "homelab-network", 
		"NETWORK_NAS": "nas-network",
		"SERVICE_TYPE": "LoadBalancer",
		"ARGO_CLUSTER_NAME": "homelab",
		"ARGO_CLUSTER_DOMAIN": "cluster.local",
		"FLUXCD_OWNER": "fredericrous",
		"FLUXCD_REPOSITORY": "homelab",
	}
	
	for key, value := range defaults {
		if os.Getenv(key) == "" {
			os.Setenv(key, value)
			log.Debug("Set default value", "key", key, "value", value)
		}
	}
	
	// Harbor defaults
	if os.Getenv("ARGO_HARBOR_IP") == "" {
		// Try to detect based on network
		if cp := os.Getenv("CONTROL_PLANE_IP"); cp != "" {
			parts := strings.Split(cp, ".")
			if len(parts) == 4 {
				harborIP := fmt.Sprintf("%s.%s.%s.90", parts[0], parts[1], parts[2])
				os.Setenv("ARGO_HARBOR_IP", harborIP)
				log.Debug("Auto-detected Harbor IP", "ip", harborIP)
			}
		}
	}
	
	if os.Getenv("ARGO_HARBOR_REGISTRY") == "" && os.Getenv("EXTERNAL_DOMAIN") != "" {
		os.Setenv("ARGO_HARBOR_REGISTRY", fmt.Sprintf("harbor.%s", os.Getenv("EXTERNAL_DOMAIN")))
	}
	
	if os.Getenv("ARGO_HARBOR_REGISTRY_TLS") == "" {
		os.Setenv("ARGO_HARBOR_REGISTRY_TLS", "true")
	}
}

// getLocalIP gets the local IP address
func (ad *AutoDetector) getLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				ip := ipnet.IP.String()
				// Skip docker/kubernetes internal IPs
				if !strings.HasPrefix(ip, "172.") && !strings.HasPrefix(ip, "10.") {
					return ip
				}
			}
		}
	}
	
	// Fallback to any non-loopback IP
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				return ipnet.IP.String()
			}
		}
	}
	
	return ""
}