package security

import (
	"context"
	"fmt"
	"strings"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// SecurityValidator validates cluster security posture
type SecurityValidator struct {
	client *k8s.Client
}

// SecurityStatus represents the security posture of the cluster
type SecurityStatus struct {
	PodSecurityPolicies    bool              `json:"pod_security_policies"`
	NetworkPolicies        bool              `json:"network_policies"`
	RBACEnabled            bool              `json:"rbac_enabled"`
	ServiceAccountSecurity bool              `json:"service_account_security"`
	SecretsEncryption      bool              `json:"secrets_encryption"`
	AdmissionControllers   []string          `json:"admission_controllers"`
	SecurityScanning       bool              `json:"security_scanning"`
	ComplianceChecks       map[string]bool   `json:"compliance_checks"`
	Vulnerabilities        []SecurityFinding `json:"vulnerabilities"`
}

// SecurityFinding represents a security issue or vulnerability
type SecurityFinding struct {
	Severity    string `json:"severity"`
	Component   string `json:"component"`
	Description string `json:"description"`
	Remediation string `json:"remediation"`
}

// NewSecurityValidator creates a new security validator
func NewSecurityValidator(client *k8s.Client) *SecurityValidator {
	return &SecurityValidator{
		client: client,
	}
}

// ValidateClusterSecurity performs comprehensive security validation
func (sv *SecurityValidator) ValidateClusterSecurity(ctx context.Context) (*SecurityStatus, error) {
	log.Info("Performing comprehensive security validation")

	status := &SecurityStatus{
		ComplianceChecks: make(map[string]bool),
		Vulnerabilities:  []SecurityFinding{},
	}

	// Check Pod Security Policies
	if err := sv.checkPodSecurityPolicies(ctx, status); err != nil {
		log.Warn("Pod Security Policy validation failed", "error", err)
	}

	// Check Network Policies
	if err := sv.checkNetworkPolicies(ctx, status); err != nil {
		log.Warn("Network Policy validation failed", "error", err)
	}

	// Check RBAC Configuration
	if err := sv.checkRBACConfiguration(ctx, status); err != nil {
		log.Warn("RBAC validation failed", "error", err)
	}

	// Check Service Account Security
	if err := sv.checkServiceAccountSecurity(ctx, status); err != nil {
		log.Warn("Service Account security validation failed", "error", err)
	}

	// Check Secrets Encryption
	if err := sv.checkSecretsEncryption(ctx, status); err != nil {
		log.Warn("Secrets encryption validation failed", "error", err)
	}

	// Check Admission Controllers
	if err := sv.checkAdmissionControllers(ctx, status); err != nil {
		log.Warn("Admission controller validation failed", "error", err)
	}

	// Perform compliance checks
	sv.performComplianceChecks(ctx, status)

	log.Info("Security validation completed",
		"rbac_enabled", status.RBACEnabled,
		"network_policies", status.NetworkPolicies,
		"vulnerabilities", len(status.Vulnerabilities))

	return status, nil
}

// checkPodSecurityPolicies validates Pod Security Policy configuration
func (sv *SecurityValidator) checkPodSecurityPolicies(ctx context.Context, status *SecurityStatus) error {
	clientset := sv.client.GetClientset()

	// Check for Pod Security Standards (newer approach replacing PSPs)
	namespaces, err := clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err == nil {
		foundPSS := false
		for _, ns := range namespaces.Items {
			if labels := ns.GetLabels(); labels != nil {
				if _, exists := labels["pod-security.kubernetes.io/enforce"]; exists {
					foundPSS = true
					break
				}
			}
		}

		if foundPSS {
			status.PodSecurityPolicies = true
			log.Info("Pod Security Standards found")
		} else {
			status.PodSecurityPolicies = false
			status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
				Severity:    "Medium",
				Component:   "Pod Security",
				Description: "No Pod Security Standards configured",
				Remediation: "Configure Pod Security Standards on namespaces",
			})
		}
	} else {
		status.PodSecurityPolicies = false
		status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
			Severity:    "Medium",
			Component:   "Pod Security",
			Description: "Cannot verify Pod Security configuration",
			Remediation: "Ensure Pod Security Standards are configured",
		})
	}

	return nil
}

// checkNetworkPolicies validates Network Policy configuration
func (sv *SecurityValidator) checkNetworkPolicies(ctx context.Context, status *SecurityStatus) error {
	clientset := sv.client.GetClientset()

	// Check for Network Policies across all namespaces
	networkPolicies, err := clientset.NetworkingV1().NetworkPolicies("").List(ctx, metav1.ListOptions{})
	if err != nil {
		status.NetworkPolicies = false
		return fmt.Errorf("failed to list network policies: %w", err)
	}

	if len(networkPolicies.Items) > 0 {
		status.NetworkPolicies = true
		log.Info("Network Policies configured", "count", len(networkPolicies.Items))

		// Check if critical namespaces have network policies
		criticalNamespaces := []string{"kube-system", "istio-system", "monitoring"}
		for _, ns := range criticalNamespaces {
			hasPolicy := false
			for _, np := range networkPolicies.Items {
				if np.Namespace == ns {
					hasPolicy = true
					break
				}
			}
			if !hasPolicy {
				status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
					Severity:    "High",
					Component:   "Network Security",
					Description: fmt.Sprintf("Critical namespace %s lacks network policies", ns),
					Remediation: fmt.Sprintf("Configure network policies for namespace %s", ns),
				})
			}
		}
	} else {
		status.NetworkPolicies = false
		status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
			Severity:    "High",
			Component:   "Network Security",
			Description: "No Network Policies configured - all pod communication allowed",
			Remediation: "Configure Network Policies to restrict pod-to-pod communication",
		})
	}

	return nil
}

// checkRBACConfiguration validates RBAC setup
func (sv *SecurityValidator) checkRBACConfiguration(ctx context.Context, status *SecurityStatus) error {
	clientset := sv.client.GetClientset()

	// Check if RBAC is enabled by trying to list ClusterRoles
	clusterRoles, err := clientset.RbacV1().ClusterRoles().List(ctx, metav1.ListOptions{})
	if err != nil {
		status.RBACEnabled = false
		status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
			Severity:    "Critical",
			Component:   "Authorization",
			Description: "RBAC appears to be disabled",
			Remediation: "Enable RBAC authorization mode",
		})
		return err
	}

	status.RBACEnabled = true
	log.Info("RBAC is enabled", "cluster_roles", len(clusterRoles.Items))

	// Check for overly permissive ClusterRoleBindings
	clusterRoleBindings, err := clientset.RbacV1().ClusterRoleBindings().List(ctx, metav1.ListOptions{})
	if err == nil {
		for _, binding := range clusterRoleBindings.Items {
			if binding.RoleRef.Name == "cluster-admin" {
				for _, subject := range binding.Subjects {
					if subject.Kind == "User" && (subject.Name == "system:anonymous" || subject.Name == "*") {
						status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
							Severity:    "Critical",
							Component:   "Authorization",
							Description: "Anonymous user has cluster-admin privileges",
							Remediation: "Remove anonymous cluster-admin access",
						})
					}
				}
			}
		}
	}

	return nil
}

// checkServiceAccountSecurity validates service account configurations
func (sv *SecurityValidator) checkServiceAccountSecurity(ctx context.Context, status *SecurityStatus) error {
	clientset := sv.client.GetClientset()

	// Check service accounts in critical namespaces
	criticalNamespaces := []string{"kube-system", "istio-system", "monitoring", "velero"}
	hasIssues := false

	for _, ns := range criticalNamespaces {
		serviceAccounts, err := clientset.CoreV1().ServiceAccounts(ns).List(ctx, metav1.ListOptions{})
		if err != nil {
			continue
		}

		for _, sa := range serviceAccounts.Items {
			// Check if service account auto-mounts tokens
			if sa.AutomountServiceAccountToken == nil || *sa.AutomountServiceAccountToken {
				// Check if this SA is bound to powerful roles
				roleBindings, err := clientset.RbacV1().RoleBindings(ns).List(ctx, metav1.ListOptions{})
				if err == nil {
					for _, binding := range roleBindings.Items {
						for _, subject := range binding.Subjects {
							if subject.Kind == "ServiceAccount" && subject.Name == sa.Name {
								if strings.Contains(binding.RoleRef.Name, "admin") || strings.Contains(binding.RoleRef.Name, "edit") {
									hasIssues = true
									status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
										Severity:    "Medium",
										Component:   "Service Account Security",
										Description: fmt.Sprintf("Service account %s/%s auto-mounts tokens and has elevated privileges", ns, sa.Name),
										Remediation: "Disable auto-mounting of service account tokens where not needed",
									})
								}
							}
						}
					}
				}
			}
		}
	}

	status.ServiceAccountSecurity = !hasIssues
	if !hasIssues {
		log.Info("Service account security validated")
	}

	return nil
}

// checkSecretsEncryption validates if secrets are encrypted at rest
func (sv *SecurityValidator) checkSecretsEncryption(ctx context.Context, status *SecurityStatus) error {
	// This is challenging to validate from within the cluster
	// We can check for indicators of encryption configuration

	clientset := sv.client.GetClientset()

	// Check for encryption configuration ConfigMaps or indications
	configMaps, err := clientset.CoreV1().ConfigMaps("kube-system").List(ctx, metav1.ListOptions{})
	if err == nil {
		for _, cm := range configMaps.Items {
			if strings.Contains(cm.Name, "encryption") || strings.Contains(cm.Name, "kms") {
				status.SecretsEncryption = true
				log.Info("Secrets encryption configuration found")
				return nil
			}
		}
	}

	// For managed clusters, assume encryption is enabled
	// For self-managed, this would need to be configured explicitly
	status.SecretsEncryption = false
	status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
		Severity:    "Medium",
		Component:   "Data Protection",
		Description: "Cannot verify secrets encryption at rest",
		Remediation: "Ensure etcd encryption is configured for secrets",
	})

	return nil
}

// checkAdmissionControllers validates admission controller configuration
func (sv *SecurityValidator) checkAdmissionControllers(ctx context.Context, status *SecurityStatus) error {
	// This is difficult to check from within the cluster
	// We can check for evidence of admission controllers by looking at webhooks

	clientset := sv.client.GetClientset()

	status.AdmissionControllers = []string{}

	// Check admission webhooks using raw API calls
	// ValidatingAdmissionWebhooks
	validatingResult, err := clientset.CoreV1().RESTClient().
		Get().
		AbsPath("/apis/admissionregistration.k8s.io/v1/validatingadmissionwebhooks").
		DoRaw(ctx)
	if err == nil && len(validatingResult) > 0 {
		status.AdmissionControllers = append(status.AdmissionControllers, "validating-webhooks")
	}

	// MutatingAdmissionWebhooks
	mutatingResult, err := clientset.CoreV1().RESTClient().
		Get().
		AbsPath("/apis/admissionregistration.k8s.io/v1/mutatingadmissionwebhooks").
		DoRaw(ctx)
	if err == nil && len(mutatingResult) > 0 {
		status.AdmissionControllers = append(status.AdmissionControllers, "mutating-webhooks")
	}

	if len(status.AdmissionControllers) > 0 {
		log.Info("Admission controllers found", "count", len(status.AdmissionControllers))
	} else {
		status.Vulnerabilities = append(status.Vulnerabilities, SecurityFinding{
			Severity:    "Medium",
			Component:   "Admission Control",
			Description: "No custom admission controllers detected",
			Remediation: "Consider implementing admission controllers for security policies",
		})
	}

	return nil
}

// performComplianceChecks runs various compliance validations
func (sv *SecurityValidator) performComplianceChecks(ctx context.Context, status *SecurityStatus) {
	log.Info("Performing compliance checks")

	// CIS Kubernetes Benchmark checks
	status.ComplianceChecks["cis_rbac_enabled"] = status.RBACEnabled
	status.ComplianceChecks["cis_network_policies"] = status.NetworkPolicies
	status.ComplianceChecks["cis_pod_security"] = status.PodSecurityPolicies

	// NIST checks
	status.ComplianceChecks["nist_access_control"] = status.RBACEnabled && status.ServiceAccountSecurity
	status.ComplianceChecks["nist_data_protection"] = status.SecretsEncryption

	// SOC2 checks
	status.ComplianceChecks["soc2_access_monitoring"] = len(status.AdmissionControllers) > 0
	status.ComplianceChecks["soc2_network_security"] = status.NetworkPolicies

	compliantChecks := 0
	for _, compliant := range status.ComplianceChecks {
		if compliant {
			compliantChecks++
		}
	}

	log.Info("Compliance checks completed",
		"compliant", compliantChecks,
		"total", len(status.ComplianceChecks))
}
