package vault

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TransitManager handles Vault transit token operations
type TransitManager struct {
	config    *config.Config
	k8sClient *k8s.Client
	isNAS     bool
}

// NewTransitManager creates a new transit manager
func NewTransitManager(cfg *config.Config, k8sClient *k8s.Client, isNAS bool) *TransitManager {
	return &TransitManager{
		config:    cfg,
		k8sClient: k8sClient,
		isNAS:     isNAS,
	}
}

// EnsureTransitToken ensures a transit token exists for vault auto-unseal
func (tm *TransitManager) EnsureTransitToken(ctx context.Context) (string, error) {
	if tm.isNAS {
		// NAS doesn't need transit token, it's the transit provider
		return "", nil
	}

	log.Info("Ensuring Vault transit token")

	// First, check if token already exists in cluster
	existingToken, err := tm.getExistingTransitToken(ctx)
	if err == nil && existingToken != "" {
		log.Info("Found existing transit token in cluster")
		return existingToken, nil
	}

	// Try to discover NAS Vault
	nasVaultAddr, err := tm.discoverNASVault(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to discover NAS Vault: %w", err)
	}

	// Check if we have root token in environment
	rootToken := tm.getRootTokenFromEnv()
	if rootToken == "" {
		// Try to get from NAS cluster if accessible
		rootToken, err = tm.getRootTokenFromNAS(ctx)
		if err != nil {
			log.Warn("Cannot obtain root token automatically", "error", err)
			return "", fmt.Errorf("Vault root token not available - please set QNAP_VAULT_TOKEN in .env")
		}
	}

	// Generate transit token
	transitToken, err := tm.generateTransitToken(ctx, nasVaultAddr, rootToken)
	if err != nil {
		return "", fmt.Errorf("failed to generate transit token: %w", err)
	}

	log.Info("Successfully generated Vault transit token")
	return transitToken, nil
}

// getExistingTransitToken checks if transit token already exists
func (tm *TransitManager) getExistingTransitToken(ctx context.Context) (string, error) {
	secret, err := tm.k8sClient.GetSecret(ctx, "vault", "vault-transit-token")
	if err != nil {
		return "", err
	}
	
	if token, ok := secret.Data["token"]; ok && len(token) > 0 {
		return string(token), nil
	}
	
	return "", fmt.Errorf("token not found in secret")
}

// discoverNASVault discovers NAS Vault endpoint
func (tm *TransitManager) discoverNASVault(ctx context.Context) (string, error) {
	// Try to discover via service if in mesh
	service, err := tm.k8sClient.GetService(ctx, "vault", "vault-vault-nas")
	if err == nil && service != nil {
		// Found service, construct URL
		return fmt.Sprintf("http://%s.%s.svc.cluster.local:8200", service.Name, service.Namespace), nil
	}

	// Try environment variable
	if addr := strings.TrimSpace(os.Getenv("QNAP_VAULT_ADDR")); addr != "" {
		return addr, nil
	}
	
	// Try alternate env vars
	for _, key := range []string{"NAS_VAULT_ADDR", "ARGO_NAS_VAULT_ADDR"} {
		if addr := strings.TrimSpace(os.Getenv(key)); addr != "" {
			return addr, nil
		}
	}

	// Try default based on NAS IP from config
	if tm.config.Homelab != nil && len(tm.config.Homelab.Cluster.Nodes) > 0 {
		// Assume NAS is on same network, just different host
		parts := strings.Split(tm.config.Homelab.Cluster.Nodes[0], ".")
		if len(parts) == 4 {
			// Replace last octet with common NAS IP
			nasIP := fmt.Sprintf("%s.%s.%s.42", parts[0], parts[1], parts[2])
			return fmt.Sprintf("http://%s:61200", nasIP), nil
		}
	}

	// Try mesh endpoint
	return "http://vault.vault.global:8200", fmt.Errorf("using mesh endpoint as fallback")
}

// getRootTokenFromEnv gets root token from environment
func (tm *TransitManager) getRootTokenFromEnv() string {
	// Check various possible env vars
	for _, key := range []string{"QNAP_VAULT_TOKEN", "VAULT_ROOT_TOKEN", "NAS_VAULT_TOKEN"} {
		if token := strings.TrimSpace(os.Getenv(key)); token != "" {
			return token
		}
	}
	return ""
}

// getRootTokenFromNAS attempts to get root token from NAS cluster
func (tm *TransitManager) getRootTokenFromNAS(ctx context.Context) (string, error) {
	// This would require NAS kubeconfig which might not be available
	// For now, return error to force manual configuration
	return "", fmt.Errorf("automatic root token retrieval not implemented")
}

// generateTransitToken generates a new transit token
func (tm *TransitManager) generateTransitToken(ctx context.Context, vaultAddr, rootToken string) (string, error) {
	client := &http.Client{Timeout: 30 * time.Second}

	// First, ensure transit engine is enabled
	if err := tm.ensureTransitEngine(ctx, client, vaultAddr, rootToken); err != nil {
		return "", fmt.Errorf("failed to ensure transit engine: %w", err)
	}

	// Create or update transit key
	if err := tm.ensureTransitKey(ctx, client, vaultAddr, rootToken); err != nil {
		return "", fmt.Errorf("failed to ensure transit key: %w", err)
	}

	// Create policy for transit access
	if err := tm.createTransitPolicy(ctx, client, vaultAddr, rootToken); err != nil {
		return "", fmt.Errorf("failed to create transit policy: %w", err)
	}

	// Generate token with policy
	token, err := tm.createToken(ctx, client, vaultAddr, rootToken)
	if err != nil {
		return "", fmt.Errorf("failed to create token: %w", err)
	}

	return token, nil
}

// ensureTransitEngine ensures transit secrets engine is enabled
func (tm *TransitManager) ensureTransitEngine(ctx context.Context, client *http.Client, vaultAddr, rootToken string) error {
	// Check if already enabled
	req, err := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("%s/v1/sys/mounts", vaultAddr), nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Vault-Token", rootToken)

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 200 {
		var result map[string]interface{}
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			return err
		}
		
		if mounts, ok := result["data"].(map[string]interface{}); ok {
			if _, exists := mounts["transit/"]; exists {
				log.Debug("Transit engine already enabled")
				return nil
			}
		}
	}

	// Enable transit engine
	payload := map[string]interface{}{
		"type": "transit",
	}
	
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err = http.NewRequestWithContext(ctx, "POST", fmt.Sprintf("%s/v1/sys/mounts/transit", vaultAddr), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("X-Vault-Token", rootToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err = client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 204 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to enable transit engine: %s", string(body))
	}

	log.Info("Transit engine enabled")
	return nil
}

// ensureTransitKey ensures the transit key exists
func (tm *TransitManager) ensureTransitKey(ctx context.Context, client *http.Client, vaultAddr, rootToken string) error {
	// Check if key exists
	req, err := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("%s/v1/transit/keys/autounseal", vaultAddr), nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Vault-Token", rootToken)

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 200 {
		log.Debug("Transit key already exists")
		return nil
	}

	// Create transit key
	req, err = http.NewRequestWithContext(ctx, "POST", fmt.Sprintf("%s/v1/transit/keys/autounseal", vaultAddr), nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Vault-Token", rootToken)

	resp, err = client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 204 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to create transit key: %s", string(body))
	}

	log.Info("Transit key created")
	return nil
}

// createTransitPolicy creates the policy for transit access
func (tm *TransitManager) createTransitPolicy(ctx context.Context, client *http.Client, vaultAddr, rootToken string) error {
	policy := `
path "transit/encrypt/autounseal" {
  capabilities = ["update"]
}

path "transit/decrypt/autounseal" {
  capabilities = ["update"]
}

path "transit/keys/autounseal" {
  capabilities = ["read"]
}
`

	payload := map[string]interface{}{
		"policy": policy,
	}
	
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, "PUT", fmt.Sprintf("%s/v1/sys/policies/acl/autounseal", vaultAddr), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("X-Vault-Token", rootToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 204 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to create policy: %s", string(body))
	}

	log.Info("Transit policy created")
	return nil
}

// createToken creates a token with the transit policy
func (tm *TransitManager) createToken(ctx context.Context, client *http.Client, vaultAddr, rootToken string) (string, error) {
	payload := map[string]interface{}{
		"policies": []string{"autounseal"},
		"ttl":      "8760h", // 1 year
		"renewable": true,
		"metadata": map[string]string{
			"purpose": "k8s-vault-autounseal",
			"cluster": "homelab",
		},
	}
	
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", fmt.Sprintf("%s/v1/auth/token/create", vaultAddr), bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("X-Vault-Token", rootToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("failed to create token: %s", string(body))
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}

	if auth, ok := result["auth"].(map[string]interface{}); ok {
		if token, ok := auth["client_token"].(string); ok {
			return token, nil
		}
	}

	return "", fmt.Errorf("token not found in response")
}

// StoreTransitToken stores the transit token in Kubernetes
func (tm *TransitManager) StoreTransitToken(ctx context.Context, token string) error {
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "vault-transit-token",
			Namespace: "vault",
			Annotations: map[string]string{
				"generated-by": "bootstrap",
				"generated-at": time.Now().Format(time.RFC3339),
			},
		},
		Type: corev1.SecretTypeOpaque,
		Data: map[string][]byte{
			"token": []byte(token),
			"vault_transit_token": []byte(token),
		},
	}

	// Create namespace if needed
	if err := tm.k8sClient.CreateNamespace(ctx, "vault"); err != nil {
		return fmt.Errorf("failed to create vault namespace: %w", err)
	}

	// Create the secret
	if err := tm.k8sClient.CreateOrUpdateSecret(ctx, secret); err != nil {
		return fmt.Errorf("failed to create transit token secret: %w", err)
	}

	log.Info("Transit token stored in Kubernetes")
	return nil
}