package discovery

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/charmbracelet/log"
	"k8s.io/client-go/rest"
	clientcmd "k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

// ClusterInfo describes a discovered cluster context.
type ClusterInfo struct {
	Name       string
	Context    string
	Kubeconfig string
	APIServer  string
	Network    string
	IsNAS      bool
}

// ClusterDiscovery loads cluster information from known kubeconfig contexts.
type ClusterDiscovery struct {
	projectRoot string

	mu         sync.Mutex
	discovered map[string]*ClusterInfo

	contextOverrides map[string]string
}

// NewClusterDiscovery creates a discovery helper rooted at projectRoot.
func NewClusterDiscovery(projectRoot string) *ClusterDiscovery {
	return &ClusterDiscovery{
		projectRoot:      projectRoot,
		discovered:       make(map[string]*ClusterInfo),
		contextOverrides: make(map[string]string),
	}
}

// WithContextOverride forces a specific context name to map to a logical cluster.
func (cd *ClusterDiscovery) WithContextOverride(cluster string, context string) *ClusterDiscovery {
	if cluster == "" || context == "" {
		return cd
	}
	cd.contextOverrides[strings.ToLower(cluster)] = context
	return cd
}

// DiscoverClusters scans known kubeconfig files and returns cluster information.
func (cd *ClusterDiscovery) DiscoverClusters(ctx context.Context) ([]*ClusterInfo, error) {
	paths := cd.candidateKubeconfigs()
	var clusters []*ClusterInfo

	for _, path := range paths {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		if _, err := os.Stat(path); err != nil {
			continue
		}

		cfg, err := clientcmd.LoadFromFile(path)
		if err != nil {
			log.Warn("Failed to load kubeconfig", "path", path, "error", err)
			continue
		}

		for ctxName, ctxCfg := range cfg.Contexts {
			clusterName := cd.logicalNameForContext(ctxName)
			if clusterName == "" {
				continue
			}

			clusterCfg, ok := cfg.Clusters[ctxCfg.Cluster]
			if !ok {
				log.Warn("Context references undefined cluster", "context", ctxName, "cluster", ctxCfg.Cluster, "path", path)
				continue
			}

			info := &ClusterInfo{
				Name:       clusterName,
				Context:    ctxName,
				Kubeconfig: path,
				APIServer:  clusterCfg.Server,
			}

			if strings.Contains(strings.ToLower(clusterName), "nas") {
				info.IsNAS = true
				info.Network = "nas-network"
			} else {
				info.Network = "homelab-network"
			}

			clusters = append(clusters, info)
			cd.storeCluster(info)
		}
	}

	log.Info("Cluster discovery via kubecontexts completed", "found", len(clusters))
	return clusters, nil
}

// ListContexts returns the preferred context for each logical cluster.
func (cd *ClusterDiscovery) ListContexts(ctx context.Context) (map[string]*ClusterInfo, error) {
	clusters, err := cd.DiscoverClusters(ctx)
	if err != nil {
		return nil, err
	}

	result := make(map[string]*ClusterInfo, len(clusters))
	for _, cluster := range clusters {
		existing, ok := result[cluster.Name]
		if !ok || cd.prefer(candidateSource(cluster.Kubeconfig), candidateSource(existing.Kubeconfig)) {
			result[cluster.Name] = cluster
		}
	}

	return result, nil
}

// GetCluster returns an already-discovered cluster by logical name.
func (cd *ClusterDiscovery) GetCluster(name string) (*ClusterInfo, error) {
	cd.mu.Lock()
	defer cd.mu.Unlock()

	if info, ok := cd.discovered[name]; ok {
		return info, nil
	}
	return nil, fmt.Errorf("cluster %s not found", name)
}

// LoadRawConfig returns the raw kubeconfig for a path.
func LoadRawConfig(path string) (*clientcmdapi.Config, error) {
	return clientcmd.LoadFromFile(path)
}

func (cd *ClusterDiscovery) storeCluster(info *ClusterInfo) {
	cd.mu.Lock()
	defer cd.mu.Unlock()
	cd.discovered[info.Name] = info
}

func (cd *ClusterDiscovery) logicalNameForContext(context string) string {
	if context == "" {
		return ""
	}

	lower := strings.ToLower(context)
	if override, ok := cd.contextOverrides[lower]; ok {
		return override
	}

	switch {
	case lower == "nas":
		return "nas"
	case lower == "homelab":
		return "homelab"
	case strings.Contains(lower, "nas"):
		return "nas"
	case strings.Contains(lower, "homelab"):
		return "homelab"
	default:
		return ""
	}
}

func (cd *ClusterDiscovery) candidateKubeconfigs() []string {
	var paths []string
	if cd.projectRoot != "" {
		paths = append(paths,
			filepath.Join(cd.projectRoot, "infrastructure", "kubeconfig"),
			filepath.Join(cd.projectRoot, "infrastructure", "homelab", "kubeconfig.yaml"),
			filepath.Join(cd.projectRoot, "infrastructure", "nas", "kubeconfig.yaml"),
			filepath.Join(cd.projectRoot, "kubeconfig"),
		)
	}

	if env := os.Getenv("KUBECONFIG"); env != "" {
		parts := strings.Split(env, string(os.PathListSeparator))
		for _, p := range parts {
			if strings.TrimSpace(p) != "" {
				paths = append(paths, p)
			}
		}
	}

	if env := os.Getenv("HOMELAB_KUBECONFIG_PATH"); env != "" {
		paths = append(paths, env)
	}
	if env := os.Getenv("NAS_KUBECONFIG_PATH"); env != "" {
		paths = append(paths, env)
	}

	paths = append(paths, filepath.Join(os.Getenv("HOME"), ".kube", "config"))
	return uniqueStrings(paths)
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	var result []string
	for _, value := range values {
		if value == "" {
			continue
		}
		value = filepath.Clean(value)
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

type sourceType int

const (
	sourceUnknown sourceType = iota
	sourceMerged
	sourceClusterSpecific
	sourceUserHome
)

func candidateSource(path string) sourceType {
	if strings.Contains(path, string(filepath.Separator)+"infrastructure"+string(filepath.Separator)+"kubeconfig") {
		return sourceMerged
	}
	if strings.Contains(path, string(filepath.Separator)+"infrastructure"+string(filepath.Separator)+"homelab") ||
		strings.Contains(path, string(filepath.Separator)+"infrastructure"+string(filepath.Separator)+"nas") {
		return sourceClusterSpecific
	}
	if strings.HasPrefix(path, filepath.Join(os.Getenv("HOME"), ".kube")) {
		return sourceUserHome
	}
	return sourceUnknown
}

func (cd *ClusterDiscovery) prefer(candidate, current sourceType) bool {
	if candidate == current {
		return false
	}

	// Highest priority: merged kubeconfig
	order := map[sourceType]int{
		sourceMerged:          3,
		sourceClusterSpecific: 2,
		sourceUserHome:        1,
		sourceUnknown:         0,
	}

	return order[candidate] > order[current]
}

// LoadNAS loads a NAS kubeconfig from the provided path (or default location)
// and returns a rest.Config ready for use with client-go.
func LoadNAS(cfgPath string) (*rest.Config, error) {
	return loadClusterConfig(cfgPath, "nas", "nas")
}

// LoadHomelab loads a homelab kubeconfig from the provided path (or default location).
func LoadHomelab(cfgPath string) (*rest.Config, error) {
	return loadClusterConfig(cfgPath, "homelab", "homelab")
}

func loadClusterConfig(path, cluster, context string) (*rest.Config, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		path = filepath.Join("infrastructure", cluster, "kubeconfig.yaml")
	}
	if !filepath.IsAbs(path) {
		abs, err := filepath.Abs(path)
		if err == nil {
			path = abs
		}
	}
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("kubeconfig not available at %s: %w", path, err)
	}

	loadingRules := &clientcmd.ClientConfigLoadingRules{ExplicitPath: path}
	overrides := &clientcmd.ConfigOverrides{}
	if context != "" {
		overrides.CurrentContext = context
	}

	clientConfig := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(loadingRules, overrides)
	cfg, err := clientConfig.ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to build config from %s: %w", path, err)
	}

	return cfg, nil
}
