package secrets

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Manager handles secret creation and management for the cluster
type Manager struct {
	client      *k8s.Client
	projectRoot string
}

// NewManager creates a new secrets manager
func NewManager(client *k8s.Client, projectRoot string) *Manager {
	return &Manager{
		client:      client,
		projectRoot: projectRoot,
	}
}

// CreateClusterVarsSecret creates cluster-vars secret from .env file
func (m *Manager) CreateClusterVarsSecret(ctx context.Context, namespace string) error {
	log.Info("Creating cluster-vars secret from .env variables", "namespace", namespace)

	envFile := filepath.Join(m.projectRoot, ".env")
	if _, err := os.Stat(envFile); os.IsNotExist(err) {
		return fmt.Errorf(".env file not found at %s", envFile)
	}

	// Parse .env file
	vars, err := m.parseEnvFile(envFile)
	if err != nil {
		return fmt.Errorf("failed to parse .env file: %w", err)
	}

	if len(vars) == 0 {
		log.Warn("No variables found in .env file")
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

	// Try to load from .env file
	envFile := filepath.Join(m.projectRoot, ".env")
	if _, err := os.Stat(envFile); os.IsNotExist(err) {
		return "", fmt.Errorf("VAULT_TRANSIT_TOKEN not in environment and .env file not found")
	}

	vars, err := m.parseEnvFile(envFile)
	if err != nil {
		return "", fmt.Errorf("failed to parse .env file: %w", err)
	}

	if token, exists := vars["VAULT_TRANSIT_TOKEN"]; exists && token != "" {
		log.Debug("Found vault transit token in .env file")
		return token, nil
	}

	return "", fmt.Errorf("VAULT_TRANSIT_TOKEN not found in environment or .env file")
}

// parseEnvFile parses a .env file and returns key-value pairs
func (m *Manager) parseEnvFile(filename string) (map[string]string, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	vars := make(map[string]string)
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}

		// Split on first = to handle values with = in them
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		// Remove quotes if present
		if len(value) >= 2 {
			if (value[0] == '"' && value[len(value)-1] == '"') ||
				(value[0] == '\'' && value[len(value)-1] == '\'') {
				value = value[1 : len(value)-1]
			}
		}

		// Skip if key or value is empty
		if key == "" || value == "" {
			continue
		}

		vars[key] = value
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return vars, nil
}

// getSecretKeys returns the keys from secret data for logging
func getSecretKeys(data map[string][]byte) []string {
	keys := make([]string, 0, len(data))
	for key := range data {
		keys = append(keys, key)
	}
	return keys
}
