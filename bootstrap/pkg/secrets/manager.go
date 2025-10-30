package secrets

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Manager handles secret creation and management for the cluster
type Manager struct {
	client      *k8s.Client
	projectRoot string
}

const (
	generatedEnvFilename    = ".env.generated"
	baseEnvFilename         = ".env"
	pendingRemoteSecretKey  = "payload"
	pendingRemoteSecretName = "istio-remote-secret-%s-pending"
	istioNamespace          = "istio-system"
)

// NewManager creates a new secrets manager
func NewManager(client *k8s.Client, projectRoot string) *Manager {
	return &Manager{
		client:      client,
		projectRoot: projectRoot,
	}
}

// CreateClusterVarsSecret creates cluster-vars secret from .env file
func (m *Manager) CreateClusterVarsSecret(ctx context.Context, namespace string) error {
	log.Info("Creating cluster-vars secret from environment variables", "namespace", namespace)

	vars, err := m.loadMergedEnvVars()
	if err != nil {
		return fmt.Errorf("failed to load environment variables: %w", err)
	}

	if len(vars) == 0 {
		log.Warn("No environment variables found in .env or .env.generated")
		return nil
	}

	log.Info("Found variables in .env file", "count", len(vars))

	// Create secret data
	data := make(map[string][]byte)
	for key, value := range vars {
		data[key] = []byte(value)
	}

	// Create the secret
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "cluster-vars",
			Namespace: namespace,
			Annotations: map[string]string{
				"reflector.v1.k8s.emberstack.com/reflection-allowed":      "true",
				"reflector.v1.k8s.emberstack.com/reflection-auto-enabled": "true",
			},
		},
		Type: corev1.SecretTypeOpaque,
		Data: data,
	}

	err = m.client.CreateOrUpdateSecret(ctx, secret)
	if err != nil {
		return fmt.Errorf("failed to create cluster-vars secret: %w", err)
	}

	log.Info("Cluster-vars secret created successfully", "variables", getSecretKeys(data))
	return nil
}

func (m *Manager) loadMergedEnvVars() (map[string]string, error) {
	merged := make(map[string]string)

	baseVars, err := readEnvFile(filepath.Join(m.projectRoot, baseEnvFilename))
	if err != nil {
		return nil, fmt.Errorf("failed to parse %s: %w", baseEnvFilename, err)
	}
	for k, v := range baseVars {
		if shouldSkipBaseEnvKey(k) {
			continue
		}
		merged[k] = v
	}

	generatedVars, err := readEnvFile(filepath.Join(m.projectRoot, generatedEnvFilename))
	if err != nil {
		return nil, fmt.Errorf("failed to parse %s: %w", generatedEnvFilename, err)
	}
	for k, v := range generatedVars {
		merged[k] = v
	}

	defaults := map[string]string{
		"ISTIO_HELM_REPO": "https://istio-release.storage.googleapis.com/charts",
		"ISTIO_VERSION":   "1.27.2",
		"NETWORK_NAS":     "nas-network",
		"NETWORK_HOMELAB": "homelab-network",
	}
	for key, value := range defaults {
		if existing, ok := merged[key]; !ok || strings.TrimSpace(existing) == "" {
			merged[key] = value
		}
	}

	return merged, nil
}

func shouldSkipBaseEnvKey(key string) bool {
	switch strings.ToUpper(strings.TrimSpace(key)) {
	case "HOMELAB_EW_GATEWAY_ADDR",
		"HOMELAB_EW_GATEWAY_PORT",
		"NAS_EW_GATEWAY_ADDR",
		"NAS_EW_GATEWAY_PORT":
		return true
	default:
		return false
	}
}

// CreateVaultTransitTokenSecret creates vault-transit-token secret
func (m *Manager) CreateVaultTransitTokenSecret(ctx context.Context, transitToken string) error {
	log.Info("Creating vault-transit-token secret")

	if transitToken == "" {
		// Try to load from environment or .env file
		token, err := m.getVaultTransitToken()
		if err != nil {
			return fmt.Errorf("vault transit token not provided and auto-retrieval failed: %w", err)
		}
		transitToken = token
	}

	// Create secret in vault namespace
	if err := m.createVaultTransitSecret(ctx, "vault", transitToken); err != nil {
		return fmt.Errorf("failed to create vault-transit-token in vault namespace: %w", err)
	}

	// Also create in flux-system namespace for platform-foundation
	if err := m.createVaultTransitSecret(ctx, "flux-system", transitToken); err != nil {
		return fmt.Errorf("failed to create vault-transit-token in flux-system namespace: %w", err)
	}

	if err := m.UpdateGeneratedEnv(map[string]string{"VAULT_TRANSIT_TOKEN": transitToken}); err != nil {
		log.Warn("Failed to record VAULT_TRANSIT_TOKEN in .env.generated", "error", err)
	}

	log.Info("Vault-transit-token secrets created successfully in both namespaces")
	return nil
}

// createVaultTransitSecret creates the vault-transit-token secret in a specific namespace
func (m *Manager) createVaultTransitSecret(ctx context.Context, namespace, token string) error {
	// Ensure namespace exists
	if err := m.client.CreateNamespace(ctx, namespace); err != nil {
		return fmt.Errorf("failed to create namespace %s: %w", namespace, err)
	}

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "vault-transit-token",
			Namespace: namespace,
		},
		Type: corev1.SecretTypeOpaque,
		Data: map[string][]byte{
			"vault_transit_token": []byte(token),
			"token":               []byte(token),
		},
	}

	// Add reflector annotations for vault namespace
	if namespace == "vault" {
		secret.ObjectMeta.Annotations = map[string]string{
			"reflector.v1.k8s.emberstack.com/reflection-allowed":            "true",
			"reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces": "flux-system",
			"reflector.v1.k8s.emberstack.com/reflection-auto-enabled":       "true",
		}
	}

	err := m.client.CreateOrUpdateSecret(ctx, secret)
	if err != nil {
		return fmt.Errorf("failed to create secret: %w", err)
	}

	log.Info("Vault-transit-token secret created", "namespace", namespace)
	return nil
}

// getVaultTransitToken retrieves vault transit token from environment or .env file
func (m *Manager) getVaultTransitToken() (string, error) {
	// Check environment variable first
	if token := os.Getenv("VAULT_TRANSIT_TOKEN"); token != "" {
		log.Debug("Found vault transit token in environment")
		return token, nil
	}

	vars, err := m.loadMergedEnvVars()
	if err != nil {
		return "", err
	}

	if token, exists := vars["VAULT_TRANSIT_TOKEN"]; exists && token != "" {
		log.Debug("Found vault transit token in local env files")
		return token, nil
	}

	return "", fmt.Errorf("VAULT_TRANSIT_TOKEN not found in environment or env files")
}

// parseEnvFile parses a .env file and returns key-value pairs
// UpdateGeneratedEnv merges the provided key/value pairs into .env.generated.
func (m *Manager) UpdateGeneratedEnv(updates map[string]string) error {
	if len(updates) == 0 {
		return nil
	}

	path := filepath.Join(m.projectRoot, generatedEnvFilename)
	env, err := NewEnvFile(path)
	if err != nil {
		return fmt.Errorf("failed to read %s: %w", generatedEnvFilename, err)
	}

	for key, value := range updates {
		env.Set(key, value)
	}

	return env.Write()
}

// GetGeneratedEnvValue returns a value from .env.generated if present.
func (m *Manager) GetGeneratedEnvValue(key string) (string, error) {
	if strings.TrimSpace(key) == "" {
		return "", nil
	}
	env, err := NewEnvFile(filepath.Join(m.projectRoot, generatedEnvFilename))
	if err != nil {
		return "", fmt.Errorf("failed to read %s: %w", generatedEnvFilename, err)
	}
	return env.Get(key), nil
}

// GetEnvValue returns the value for a key from the merged .env and .env.generated content.
func (m *Manager) GetEnvValue(key string) (string, error) {
	if strings.TrimSpace(key) == "" {
		return "", nil
	}
	vars, err := m.loadMergedEnvVars()
	if err != nil {
		return "", err
	}
	return vars[key], nil
}

// StorePendingRemoteSecret persists a remote-secret payload (base64 encoded) for later reconciliation.
func (m *Manager) StorePendingRemoteSecret(ctx context.Context, cluster string, payloadB64 string) error {
	cluster = strings.TrimSpace(strings.ToLower(cluster))
	if cluster == "" {
		return fmt.Errorf("cluster name is required for pending remote secret")
	}

	name := fmt.Sprintf(pendingRemoteSecretName, cluster)

	if payloadB64 == "" {
		if err := m.client.GetClientset().CoreV1().Secrets(istioNamespace).Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
			return fmt.Errorf("failed to delete pending remote secret: %w", err)
		}
		return nil
	}

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: istioNamespace,
		},
		Type: corev1.SecretTypeOpaque,
		Data: map[string][]byte{
			pendingRemoteSecretKey: []byte(payloadB64),
		},
	}

	if err := m.client.CreateOrUpdateSecret(ctx, secret); err != nil {
		return fmt.Errorf("failed to upsert pending remote secret: %w", err)
	}

	return nil
}

// FetchPendingRemoteSecret retrieves a pending remote secret payload, if any.
func (m *Manager) FetchPendingRemoteSecret(ctx context.Context, cluster string) (string, error) {
	cluster = strings.TrimSpace(strings.ToLower(cluster))
	if cluster == "" {
		return "", nil
	}

	name := fmt.Sprintf(pendingRemoteSecretName, cluster)
	secret, err := m.client.GetClientset().CoreV1().Secrets(istioNamespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return "", nil
		}
		return "", fmt.Errorf("failed to fetch pending remote secret: %w", err)
	}

	if secret.Data == nil {
		return "", nil
	}

	return string(secret.Data[pendingRemoteSecretKey]), nil
}

// ClearPendingRemoteSecret removes the pending secret entry for a cluster.
func (m *Manager) ClearPendingRemoteSecret(ctx context.Context, cluster string) error {
	cluster = strings.TrimSpace(strings.ToLower(cluster))
	if cluster == "" {
		return nil
	}

	name := fmt.Sprintf(pendingRemoteSecretName, cluster)
	if err := m.client.GetClientset().CoreV1().Secrets(istioNamespace).Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("failed to delete pending remote secret: %w", err)
	}
	return nil
}

// getSecretKeys returns the keys from secret data for logging
func getSecretKeys(data map[string][]byte) []string {
	keys := make([]string, 0, len(data))
	for key := range data {
		keys = append(keys, key)
	}
	return keys
}

// UpdateClusterVars updates specific key-value pairs in the cluster-vars secret
func (m *Manager) UpdateClusterVars(ctx context.Context, namespace string, updates map[string]string) error {
	log.Info("Updating cluster-vars secret", "namespace", namespace, "keys", len(updates))

	// Create a timeout context for this operation
	updateCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	// Get existing secret
	secret, err := m.client.GetClientset().CoreV1().Secrets(namespace).Get(updateCtx, "cluster-vars", metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			// If secret doesn't exist, create it
			log.Info("cluster-vars secret not found, creating new one")
			return m.CreateClusterVarsSecret(ctx, namespace)
		}
		return fmt.Errorf("failed to get cluster-vars secret: %w", err)
	}

	// Update values
	if secret.Data == nil {
		secret.Data = make(map[string][]byte)
	}
	
	// Log what we're updating
	var updateKeys []string
	for key, value := range updates {
		secret.Data[key] = []byte(value)
		updateKeys = append(updateKeys, fmt.Sprintf("%s=%s", key, value))
	}
	log.Info("Updating cluster-vars values", "updates", strings.Join(updateKeys, ", "))

	// Update the secret
	if err := m.client.CreateOrUpdateSecret(updateCtx, secret); err != nil {
		return fmt.Errorf("failed to update cluster-vars secret: %w", err)
	}

	log.Info("Successfully updated cluster-vars secret")
	return nil
}

func readEnvFile(path string) (map[string]string, error) {
	env, err := NewEnvFile(path)
	if err != nil {
		return nil, err
	}
	return env.All(), nil
}
