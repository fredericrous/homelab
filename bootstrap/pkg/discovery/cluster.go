package discovery

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ClusterInfo contains discovered cluster information
type ClusterInfo struct {
	Name       string
	APIServer  string
	Network    string
	IsNAS      bool
	Kubeconfig string
}

// ClusterDiscovery handles automatic cluster discovery
type ClusterDiscovery struct {
	projectRoot string
	localClient *k8s.Client
	mu          sync.Mutex
	discovered  map[string]*ClusterInfo
}

// NewClusterDiscovery creates a new cluster discovery service
func NewClusterDiscovery(projectRoot string, localClient *k8s.Client) *ClusterDiscovery {
	return &ClusterDiscovery{
		projectRoot: projectRoot,
		localClient: localClient,
		discovered:  make(map[string]*ClusterInfo),
	}
}

// DiscoverClusters discovers available clusters
func (cd *ClusterDiscovery) DiscoverClusters(ctx context.Context) ([]*ClusterInfo, error) {
	log.Info("Starting cluster discovery")
	
	var clusters []*ClusterInfo
	var wg sync.WaitGroup
	
	// Discover via multiple methods in parallel
	methods := []func(context.Context) ([]*ClusterInfo, error){
		cd.discoverViaKubeconfigs,
		cd.discoverViaConfigMap,
		cd.discoverViaServices,
		cd.discoverViaNetwork,
	}
	
	results := make(chan []*ClusterInfo, len(methods))
	errors := make(chan error, len(methods))
	
	for _, method := range methods {
		wg.Add(1)
		go func(m func(context.Context) ([]*ClusterInfo, error)) {
			defer wg.Done()
			discovered, err := m(ctx)
			if err != nil {
				errors <- err
			} else {
				results <- discovered
			}
		}(method)
	}
	
	// Wait for all methods to complete
	go func() {
		wg.Wait()
		close(results)
		close(errors)
	}()
	
	// Collect results
	seen := make(map[string]bool)
	for discovered := range results {
		for _, cluster := range discovered {
			if !seen[cluster.Name] {
				seen[cluster.Name] = true
				clusters = append(clusters, cluster)
				cd.mu.Lock()
				cd.discovered[cluster.Name] = cluster
				cd.mu.Unlock()
			}
		}
	}
	
	// Log any errors
	for err := range errors {
		log.Debug("Discovery method error", "error", err)
	}
	
	log.Info("Cluster discovery completed", "found", len(clusters))
	return clusters, nil
}

// discoverViaKubeconfigs looks for kubeconfig files
func (cd *ClusterDiscovery) discoverViaKubeconfigs(ctx context.Context) ([]*ClusterInfo, error) {
	var clusters []*ClusterInfo
	
	// Common kubeconfig locations
	locations := []struct {
		path   string
		name   string
		isNAS  bool
	}{
		{filepath.Join(cd.projectRoot, "kubeconfig"), "homelab", false},
		{filepath.Join(cd.projectRoot, "infrastructure/nas/kubeconfig.yaml"), "nas", true},
		{filepath.Join(cd.projectRoot, "infrastructure/nas/kubeconfig"), "nas", true},
		{filepath.Join(os.Getenv("HOME"), ".kube/config"), "default", false},
	}
	
	// Add environment-based locations
	if path := os.Getenv("HOMELAB_KUBECONFIG_PATH"); path != "" {
		locations = append(locations, struct {
			path   string
			name   string
			isNAS  bool
		}{path, "homelab", false})
	}
	
	if path := os.Getenv("NAS_KUBECONFIG_PATH"); path != "" {
		locations = append(locations, struct {
			path   string
			name   string
			isNAS  bool
		}{path, "nas", true})
	}
	
	for _, loc := range locations {
		if _, err := os.Stat(loc.path); err == nil {
			// Try to connect to validate
			client, err := k8s.NewClient(loc.path)
			if err != nil {
				continue
			}
			
			// Get API server info
			if err := client.IsReady(ctx); err == nil {
				config := client.GetConfig()
				cluster := &ClusterInfo{
					Name:       loc.name,
					APIServer:  config.Host,
					IsNAS:      loc.isNAS,
					Kubeconfig: loc.path,
				}
				
				if loc.isNAS {
					cluster.Network = "nas-network"
				} else {
					cluster.Network = "homelab-network"
				}
				
				clusters = append(clusters, cluster)
				log.Debug("Found cluster via kubeconfig", "name", loc.name, "path", loc.path)
			}
		}
	}
	
	return clusters, nil
}

// discoverViaConfigMap looks for cluster info in ConfigMaps
func (cd *ClusterDiscovery) discoverViaConfigMap(ctx context.Context) ([]*ClusterInfo, error) {
	var clusters []*ClusterInfo
	
	if cd.localClient == nil {
		return clusters, nil
	}
	
	// Look for cluster discovery ConfigMap
	cm, err := cd.localClient.GetClientset().CoreV1().ConfigMaps("flux-system").Get(ctx, "cluster-discovery", metav1.GetOptions{})
	if err != nil {
		return clusters, nil // Not an error, just not found
	}
	
	// Parse cluster info from ConfigMap
	for name, data := range cm.Data {
		parts := strings.Split(data, ",")
		if len(parts) >= 3 {
			cluster := &ClusterInfo{
				Name:      name,
				APIServer: parts[0],
				Network:   parts[1],
				IsNAS:     parts[2] == "true",
			}
			clusters = append(clusters, cluster)
			log.Debug("Found cluster via ConfigMap", "name", name)
		}
	}
	
	return clusters, nil
}

// discoverViaServices looks for cross-cluster services
func (cd *ClusterDiscovery) discoverViaServices(ctx context.Context) ([]*ClusterInfo, error) {
	var clusters []*ClusterInfo
	
	if cd.localClient == nil {
		return clusters, nil
	}
	
	// Look for multicluster services
	services, err := cd.localClient.GetClientset().CoreV1().Services("").List(ctx, metav1.ListOptions{
		LabelSelector: "istio/multiCluster=true",
	})
	if err != nil {
		return clusters, nil
	}
	
	for _, svc := range services.Items {
		if clusterName := svc.Labels["cluster"]; clusterName != "" {
			cluster := &ClusterInfo{
				Name:      clusterName,
				APIServer: fmt.Sprintf("https://%s", svc.Spec.ClusterIP),
				Network:   svc.Labels["network"],
				IsNAS:     clusterName == "nas",
			}
			clusters = append(clusters, cluster)
			log.Debug("Found cluster via service", "name", clusterName)
		}
	}
	
	return clusters, nil
}

// discoverViaNetwork performs network discovery
func (cd *ClusterDiscovery) discoverViaNetwork(ctx context.Context) ([]*ClusterInfo, error) {
	var clusters []*ClusterInfo
	
	// Get local network
	localIP := cd.getLocalIP()
	if localIP == "" {
		return clusters, nil
	}
	
	// Extract network prefix
	parts := strings.Split(localIP, ".")
	if len(parts) != 4 {
		return clusters, nil
	}
	
	networkPrefix := fmt.Sprintf("%s.%s.%s", parts[0], parts[1], parts[2])
	
	// Common IPs to check
	commonIPs := []struct {
		ip    string
		name  string
		isNAS bool
	}{
		{fmt.Sprintf("%s.42", networkPrefix), "nas", true},
		{fmt.Sprintf("%s.67", networkPrefix), "homelab", false},
		{fmt.Sprintf("%s.100", networkPrefix), "cluster", false},
	}
	
	// Scan common IPs for Kubernetes API
	for _, target := range commonIPs {
		if cd.checkKubeAPI(ctx, target.ip) {
			cluster := &ClusterInfo{
				Name:      target.name,
				APIServer: fmt.Sprintf("https://%s:6443", target.ip),
				IsNAS:     target.isNAS,
			}
			
			if target.isNAS {
				cluster.Network = "nas-network"
			} else {
				cluster.Network = "homelab-network"
			}
			
			clusters = append(clusters, cluster)
			log.Debug("Found cluster via network scan", "name", target.name, "ip", target.ip)
		}
	}
	
	return clusters, nil
}

// checkKubeAPI checks if Kubernetes API is available at given IP
func (cd *ClusterDiscovery) checkKubeAPI(ctx context.Context, ip string) bool {
	// Quick TCP check on port 6443
	dialer := &net.Dialer{
		Timeout: 2 * time.Second,
	}
	
	conn, err := dialer.DialContext(ctx, "tcp", fmt.Sprintf("%s:6443", ip))
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// getLocalIP gets the local IP address
func (cd *ClusterDiscovery) getLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				return ipnet.IP.String()
			}
		}
	}
	
	return ""
}

// GetCluster returns a discovered cluster by name
func (cd *ClusterDiscovery) GetCluster(name string) (*ClusterInfo, error) {
	cd.mu.Lock()
	defer cd.mu.Unlock()
	
	if cluster, ok := cd.discovered[name]; ok {
		return cluster, nil
	}
	
	return nil, fmt.Errorf("cluster %s not found", name)
}

// StoreDiscoveryInfo stores discovery info for other clusters to find us
func (cd *ClusterDiscovery) StoreDiscoveryInfo(ctx context.Context, localClusterName string) error {
	if cd.localClient == nil {
		return fmt.Errorf("no local client available")
	}
	
	// Get our cluster info - need actual node objects
	nodeList, err := cd.localClient.GetClientset().CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to get nodes: %w", err)
	}
	
	if len(nodeList.Items) == 0 {
		return fmt.Errorf("no nodes found")
	}
	
	// Get external IP
	var externalIP string
	for _, node := range nodeList.Items {
		for _, addr := range node.Status.Addresses {
			if addr.Type == corev1.NodeExternalIP {
				externalIP = addr.Address
				break
			}
		}
		if externalIP == "" {
			// Fall back to internal IP
			for _, addr := range node.Status.Addresses {
				if addr.Type == corev1.NodeInternalIP {
					externalIP = addr.Address
					break
				}
			}
		}
		if externalIP != "" {
			break
		}
	}
	
	if externalIP == "" {
		return fmt.Errorf("no node IP found")
	}
	
	// Create discovery ConfigMap
	network := "homelab-network"
	if strings.Contains(localClusterName, "nas") {
		network = "nas-network"
	}
	
	discoveryData := fmt.Sprintf("https://%s:6443,%s,%v", externalIP, network, strings.Contains(localClusterName, "nas"))
	
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "cluster-discovery",
			Namespace: "flux-system",
			Labels: map[string]string{
				"app.kubernetes.io/name": "cluster-discovery",
				"app.kubernetes.io/part-of": "bootstrap",
			},
		},
		Data: map[string]string{
			localClusterName: discoveryData,
		},
	}
	
	// Create or update
	existing, err := cd.localClient.GetClientset().CoreV1().ConfigMaps("flux-system").Get(ctx, "cluster-discovery", metav1.GetOptions{})
	if err == nil {
		// Update existing
		if existing.Data == nil {
			existing.Data = make(map[string]string)
		}
		existing.Data[localClusterName] = discoveryData
		_, err = cd.localClient.GetClientset().CoreV1().ConfigMaps("flux-system").Update(ctx, existing, metav1.UpdateOptions{})
	} else {
		// Create new
		_, err = cd.localClient.GetClientset().CoreV1().ConfigMaps("flux-system").Create(ctx, cm, metav1.CreateOptions{})
	}
	
	if err != nil {
		return fmt.Errorf("failed to store discovery info: %w", err)
	}
	
	log.Info("Stored cluster discovery info", "cluster", localClusterName, "ip", externalIP)
	return nil
}