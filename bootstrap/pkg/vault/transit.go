package vault

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	"github.com/fredericrous/homelab/bootstrap/pkg/secrets"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TransitManager handles Vault transit token operations
type TransitManager struct {
	k8sClient   *k8s.Client
	projectRoot string
	isNAS       bool
}

// NewTransitManager creates a new transit manager
func NewTransitManager(k8sClient *k8s.Client, projectRoot string, isNAS bool) *TransitManager {
	return &TransitManager{
		k8sClient:   k8sClient,
		projectRoot: projectRoot,
		isNAS:       isNAS,
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

	// Try to load a previously generated token from environment files
	transitToken, err := tm.loadTransitTokenFromEnv()
	if err != nil {
		return "", err
	}

	log.Info("Successfully loaded Vault transit token")
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
			"token":               []byte(token),
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

func (tm *TransitManager) loadTransitTokenFromEnv() (string, error) {
	if token := strings.TrimSpace(os.Getenv("VAULT_TRANSIT_TOKEN")); token != "" {
		log.Info("Using VAULT_TRANSIT_TOKEN from environment")
		return token, nil
	}

	if strings.TrimSpace(tm.projectRoot) == "" {
		return "", fmt.Errorf("project root not configured; cannot locate .env.generated (run bootstrap nas install first)")
	}

	candidates := []string{
		filepath.Join(tm.projectRoot, ".env.generated"),
		filepath.Join(tm.projectRoot, ".env"),
	}

	for _, path := range candidates {
		envFile, err := secrets.NewEnvFile(path)
		if err != nil {
			return "", fmt.Errorf("failed to read %s: %w", filepath.Base(path), err)
		}
		if token := strings.TrimSpace(envFile.Get("VAULT_TRANSIT_TOKEN")); token != "" {
			log.Info("Loaded VAULT_TRANSIT_TOKEN from", "source", filepath.Base(path))
			return token, nil
		}
	}

	return "", fmt.Errorf("VAULT_TRANSIT_TOKEN not found; rerun './bootstrap nas install' to generate it")
}
