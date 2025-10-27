package istio

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	authv1 "k8s.io/api/authentication/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
)

const (
	istioReaderPrefix = "istio-reader"
	istioNamespace    = "istio-system"
)

// MultiClusterManager handles Istio multi-cluster configuration
type MultiClusterManager struct {
	client *k8s.Client
}

// NewMultiClusterManager creates a new multi-cluster manager
func NewMultiClusterManager(client *k8s.Client) *MultiClusterManager {
	return &MultiClusterManager{
		client: client,
	}
}

// CreateRemoteSecret creates a remote secret for cross-cluster discovery
func (m *MultiClusterManager) CreateRemoteSecret(ctx context.Context, clusterName string) (*corev1.Secret, error) {
	log.Info("Creating remote secret for cluster", "cluster", clusterName)

	// Create service account
	sa, err := m.createServiceAccount(ctx, clusterName)
	if err != nil {
		return nil, fmt.Errorf("failed to create service account: %w", err)
	}

	// Create RBAC
	if err := m.createRBAC(ctx, clusterName, sa.Name); err != nil {
		return nil, fmt.Errorf("failed to create RBAC: %w", err)
	}

	// Wait for service account token
	token, ca, err := m.waitForServiceAccountToken(ctx, sa.Name, sa.Namespace)
	if err != nil {
		return nil, fmt.Errorf("failed to get service account token: %w", err)
	}

	// Get API server address
	apiServer, err := m.getAPIServerAddress()
	if err != nil {
		return nil, fmt.Errorf("failed to get API server address: %w", err)
	}

	// Create minimal kubeconfig
	kubeconfig, err := m.createMinimalKubeconfig(clusterName, apiServer, ca, token)
	if err != nil {
		return nil, fmt.Errorf("failed to create kubeconfig: %w", err)
	}

	// Create the remote secret
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("istio-remote-secret-%s", clusterName),
			Namespace: istioNamespace,
			Labels: map[string]string{
				"istio/multiCluster": "true",
			},
		},
		Type: corev1.SecretTypeOpaque,
		Data: map[string][]byte{
			clusterName: kubeconfig,
		},
	}

	log.Info("Remote secret created", "cluster", clusterName)
	return secret, nil
}

// createServiceAccount creates a service account for cross-cluster access
func (m *MultiClusterManager) createServiceAccount(ctx context.Context, remoteCluster string) (*corev1.ServiceAccount, error) {
	saName := fmt.Sprintf("%s-%s", istioReaderPrefix, remoteCluster)
	
	sa := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      saName,
			Namespace: istioNamespace,
		},
	}

	// Create namespace if it doesn't exist
	if err := m.client.CreateNamespace(ctx, istioNamespace); err != nil {
		return nil, fmt.Errorf("failed to create namespace: %w", err)
	}

	// Create or update the service account
	existing, err := m.client.GetClientset().CoreV1().ServiceAccounts(istioNamespace).Get(ctx, saName, metav1.GetOptions{})
	if err != nil {
		if !apierrors.IsNotFound(err) {
			return nil, err
		}
		// Create new
		created, err := m.client.GetClientset().CoreV1().ServiceAccounts(istioNamespace).Create(ctx, sa, metav1.CreateOptions{})
		if err != nil {
			return nil, fmt.Errorf("failed to create service account: %w", err)
		}
		return created, nil
	}
	
	// Already exists
	return existing, nil
}

// createRBAC creates the necessary RBAC for cross-cluster discovery
func (m *MultiClusterManager) createRBAC(ctx context.Context, remoteCluster, saName string) error {
	roleName := fmt.Sprintf("%s-%s", istioReaderPrefix, remoteCluster)

	// Create ClusterRole
	clusterRole := &rbacv1.ClusterRole{
		ObjectMeta: metav1.ObjectMeta{
			Name: roleName,
		},
		Rules: []rbacv1.PolicyRule{
			{
				APIGroups: []string{""},
				Resources: []string{"nodes", "pods", "services", "endpoints"},
				Verbs:     []string{"get", "list", "watch"},
			},
			{
				APIGroups: []string{"discovery.k8s.io"},
				Resources: []string{"endpointslices"},
				Verbs:     []string{"get", "list", "watch"},
			},
			{
				APIGroups: []string{"networking.istio.io"},
				Resources: []string{"*"},
				Verbs:     []string{"get", "list", "watch"},
			},
			{
				APIGroups: []string{"security.istio.io"},
				Resources: []string{"*"},
				Verbs:     []string{"get", "list", "watch"},
			},
		},
	}

	// Create or update ClusterRole
	existingRole, err := m.client.GetClientset().RbacV1().ClusterRoles().Get(ctx, roleName, metav1.GetOptions{})
	if err != nil {
		if !apierrors.IsNotFound(err) {
			return err
		}
		if _, err := m.client.GetClientset().RbacV1().ClusterRoles().Create(ctx, clusterRole, metav1.CreateOptions{}); err != nil {
			return fmt.Errorf("failed to create cluster role: %w", err)
		}
	} else {
		existingRole.Rules = clusterRole.Rules
		if _, err := m.client.GetClientset().RbacV1().ClusterRoles().Update(ctx, existingRole, metav1.UpdateOptions{}); err != nil {
			return fmt.Errorf("failed to update cluster role: %w", err)
		}
	}

	// Create ClusterRoleBinding
	clusterRoleBinding := &rbacv1.ClusterRoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name: roleName,
		},
		RoleRef: rbacv1.RoleRef{
			APIGroup: "rbac.authorization.k8s.io",
			Kind:     "ClusterRole",
			Name:     roleName,
		},
		Subjects: []rbacv1.Subject{
			{
				Kind:      "ServiceAccount",
				Name:      saName,
				Namespace: istioNamespace,
			},
		},
	}

	// Create or update ClusterRoleBinding
	existingBinding, err := m.client.GetClientset().RbacV1().ClusterRoleBindings().Get(ctx, roleName, metav1.GetOptions{})
	if err != nil {
		if !apierrors.IsNotFound(err) {
			return err
		}
		if _, err := m.client.GetClientset().RbacV1().ClusterRoleBindings().Create(ctx, clusterRoleBinding, metav1.CreateOptions{}); err != nil {
			return fmt.Errorf("failed to create cluster role binding: %w", err)
		}
	} else {
		existingBinding.RoleRef = clusterRoleBinding.RoleRef
		existingBinding.Subjects = clusterRoleBinding.Subjects
		if _, err := m.client.GetClientset().RbacV1().ClusterRoleBindings().Update(ctx, existingBinding, metav1.UpdateOptions{}); err != nil {
			return fmt.Errorf("failed to update cluster role binding: %w", err)
		}
	}

	return nil
}

// waitForServiceAccountToken waits for and retrieves the service account token
func (m *MultiClusterManager) waitForServiceAccountToken(ctx context.Context, saName, namespace string) (string, []byte, error) {
	var token string
	var ca []byte

	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, 30*time.Second, true, func(ctx context.Context) (bool, error) {
		// Get the service account
		sa, err := m.client.GetClientset().CoreV1().ServiceAccounts(namespace).Get(ctx, saName, metav1.GetOptions{})
		if err != nil {
			return false, nil
		}

		// In Kubernetes 1.24+, we need to create a token manually
		tokenRequest := &authv1.TokenRequest{
			Spec: authv1.TokenRequestSpec{
				Audiences: []string{"https://kubernetes.default.svc.cluster.local"},
				ExpirationSeconds: int64Ptr(365 * 24 * 60 * 60), // 1 year
			},
		}

		tokenResponse, err := m.client.GetClientset().CoreV1().ServiceAccounts(namespace).CreateToken(ctx, saName, tokenRequest, metav1.CreateOptions{})
		if err != nil {
			log.Debug("Waiting for service account token", "error", err)
			return false, nil
		}

		token = tokenResponse.Status.Token
		
		// Get CA certificate from the cluster
		caSecret, err := m.client.GetClientset().CoreV1().Secrets("kube-system").Get(ctx, "kube-root-ca.crt", metav1.GetOptions{})
		if err == nil && caSecret.Data["ca.crt"] != nil {
			ca = caSecret.Data["ca.crt"]
			return true, nil
		}

		// Fallback: try to get from service account secret (pre-1.24 clusters)
		for _, secretRef := range sa.Secrets {
			secret, err := m.client.GetClientset().CoreV1().Secrets(namespace).Get(ctx, secretRef.Name, metav1.GetOptions{})
			if err != nil {
				continue
			}
			if secret.Type == corev1.SecretTypeServiceAccountToken {
				if t, ok := secret.Data["token"]; ok {
					token = string(t)
				}
				if c, ok := secret.Data["ca.crt"]; ok {
					ca = c
					return true, nil
				}
			}
		}

		return false, nil
	})

	if err != nil {
		return "", nil, fmt.Errorf("timeout waiting for service account token: %w", err)
	}

	return token, ca, nil
}

// getAPIServerAddress gets the Kubernetes API server address
func (m *MultiClusterManager) getAPIServerAddress() (string, error) {
	config := m.client.GetConfig()
	if config == nil {
		return "", fmt.Errorf("no kubeconfig available")
	}
	return config.Host, nil
}

// createMinimalKubeconfig creates a minimal kubeconfig for the service account
func (m *MultiClusterManager) createMinimalKubeconfig(clusterName, server string, ca []byte, token string) ([]byte, error) {
	kubeconfig := map[string]interface{}{
		"apiVersion": "v1",
		"kind":       "Config",
		"clusters": []map[string]interface{}{
			{
				"name": clusterName,
				"cluster": map[string]interface{}{
					"server":                   server,
					"certificate-authority-data": base64.StdEncoding.EncodeToString(ca),
				},
			},
		},
		"contexts": []map[string]interface{}{
			{
				"name": clusterName,
				"context": map[string]interface{}{
					"cluster": clusterName,
					"user":    clusterName,
				},
			},
		},
		"current-context": clusterName,
		"users": []map[string]interface{}{
			{
				"name": clusterName,
				"user": map[string]interface{}{
					"token": token,
				},
			},
		},
	}

	return json.Marshal(kubeconfig)
}

// Helper function
func int64Ptr(i int64) *int64 {
	return &i
}