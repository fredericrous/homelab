package main

import (
	"fmt"
	"os"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/internal/homelab"
	"github.com/fredericrous/homelab/bootstrap/internal/nas"
	bootstrapPkg "github.com/fredericrous/homelab/bootstrap/pkg/bootstrap"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/destroy"
	"github.com/fredericrous/homelab/bootstrap/pkg/logger"
	"github.com/fredericrous/homelab/bootstrap/pkg/recovery"
	"github.com/spf13/cobra"
)

func main() {
	// Setup beautiful logging
	logger.SetupLogger()

	// Create root command
	rootCmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Homelab and NAS cluster bootstrap tool",
		Long: `A unified command-line tool for bootstrapping homelab and NAS clusters.
		
This tool provides a consistent interface for deploying and managing both
homelab Kubernetes clusters (with Talos, Cilium, FluxCD) and NAS clusters
(with K3s, MinIO, FluxCD) using modern GitOps practices.`,
		Example: `  # Bootstrap homelab cluster
  bootstrap homelab bootstrap --no-tui
  
  # Check homelab prerequisites  
  bootstrap homelab check
  
  # Bootstrap NAS cluster
  bootstrap nas bootstrap --no-tui
  
  # Validate NAS deployment
  bootstrap nas validate`,
	}

	// Add global flags
	rootCmd.PersistentFlags().Bool("verbose", false, "Enable verbose logging")
	rootCmd.PersistentFlags().Bool("debug", false, "Enable debug logging")

	// Setup logging level based on flags
	rootCmd.PersistentPreRun = func(cmd *cobra.Command, args []string) {
		if verbose, _ := cmd.Flags().GetBool("verbose"); verbose {
			log.SetLevel(log.DebugLevel)
		}
		if debug, _ := cmd.Flags().GetBool("debug"); debug {
			log.SetLevel(log.DebugLevel)
			log.SetReportCaller(true)
		}
	}

	// Create homelab subcommand
	homelabCmd := &cobra.Command{
		Use:   "homelab",
		Short: "Homelab cluster operations",
		Long:  "Bootstrap and manage homelab Kubernetes clusters with Talos, Cilium, and FluxCD",
	}
	addClusterFlags(homelabCmd)

	// Add homelab subcommands
	homelabCmd.AddCommand(homelab.NewBootstrapCommand())
	homelabCmd.AddCommand(homelab.NewCheckCommand())
	homelabCmd.AddCommand(homelab.NewInstallCommand())
	homelabCmd.AddCommand(homelab.NewValidateCommand())
	homelabCmd.AddCommand(homelab.NewDestroyCommand())
	homelabCmd.AddCommand(homelab.NewUpCommand())
	homelabCmd.AddCommand(homelab.NewInstallCiliumCommand())
	homelabCmd.AddCommand(homelab.NewSyncSecretsCommand())
	homelabCmd.AddCommand(homelab.NewSuspendCommand())
	homelabCmd.AddCommand(homelab.NewResumeCommand())
	homelabCmd.AddCommand(homelab.NewUninstallCommand())
	homelabCmd.AddCommand(homelab.NewStatusCommand())

	// Create NAS subcommand
	nasCmd := &cobra.Command{
		Use:   "nas",
		Short: "NAS cluster operations",
		Long:  "Bootstrap and manage NAS clusters with K3s, MinIO, and FluxCD",
	}
	addClusterFlags(nasCmd)

	// Add NAS subcommands
	nasCmd.AddCommand(nas.NewBootstrapCommand())
	nasCmd.AddCommand(nas.NewCheckCommand())
	nasCmd.AddCommand(nas.NewInstallCommand())
	nasCmd.AddCommand(nas.NewValidateCommand())
	nasCmd.AddCommand(nas.NewDestroyCommand())
	nasCmd.AddCommand(nas.NewUpCommand())
	nasCmd.AddCommand(nas.NewStatusCommand())
	nasCmd.AddCommand(nas.NewUninstallCommand())
	nasCmd.AddCommand(nas.NewVaultSetupCommand())

	// Add subcommands to root
	rootCmd.AddCommand(homelabCmd)
	rootCmd.AddCommand(nasCmd)

	// Add convenience commands at root level
	rootCmd.AddCommand(createQuickCommands())
	rootCmd.AddCommand(createForceCleanupCommand())
	rootCmd.AddCommand(createRecoveryCommand())
	rootCmd.AddCommand(createVerifyCommand())

	// Add version command
	rootCmd.AddCommand(&cobra.Command{
		Use:   "version",
		Short: "Show version information",
		Run: func(cmd *cobra.Command, args []string) {
			log.Info("Bootstrap Tool", "version", "1.0.0", "commit", "dev")
		},
	})

	// Execute
	if err := rootCmd.Execute(); err != nil {
		log.Error("Command failed", "error", err)
		os.Exit(1)
	}
}

// createQuickCommands adds convenience commands for common workflows
func createQuickCommands() *cobra.Command {
	quickCmd := &cobra.Command{
		Use:   "deploy",
		Short: "Quick deploy commands",
		Long:  "Convenience commands for common deployment scenarios",
	}

	// Quick homelab deploy
	quickCmd.AddCommand(&cobra.Command{
		Use:   "homelab",
		Short: "Quick homelab deployment",
		Long:  "Deploy homelab cluster with sensible defaults",
		RunE: func(cmd *cobra.Command, args []string) error {
			log.Info("🏠 Starting homelab deployment")

			// Run the homelab bootstrap command
			homelabBootstrap := homelab.NewBootstrapCommand()
			homelabBootstrap.SetArgs(args)
			return homelabBootstrap.Execute()
		},
	})

	// Quick NAS deploy
	quickCmd.AddCommand(&cobra.Command{
		Use:   "nas",
		Short: "Quick NAS deployment",
		Long:  "Deploy NAS cluster with sensible defaults",
		RunE: func(cmd *cobra.Command, args []string) error {
			log.Info("💾 Starting NAS deployment")

			// Run the NAS bootstrap command
			nasBootstrap := nas.NewBootstrapCommand()
			nasBootstrap.SetArgs(args)
			return nasBootstrap.Execute()
		},
	})

	// Deploy both
	quickCmd.AddCommand(&cobra.Command{
		Use:   "all",
		Short: "Deploy both homelab and NAS",
		Long:  "Deploy both homelab and NAS clusters in sequence",
		RunE: func(cmd *cobra.Command, args []string) error {
			log.Info("🚀 Starting full deployment (homelab + NAS)")

			// Deploy NAS first (homelab depends on it)
			log.Info("Step 1: Deploying NAS cluster")
			nasBootstrap := nas.NewBootstrapCommand()
			if err := nasBootstrap.Execute(); err != nil {
				return err
			}

			log.Info("Step 2: Deploying homelab cluster")
			homelabBootstrap := homelab.NewBootstrapCommand()
			return homelabBootstrap.Execute()
		},
	})

	return quickCmd
}

func createVerifyCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "verify",
		Short: "Run multi-cluster verification checks",
		RunE: func(cmd *cobra.Command, args []string) error {
			log.Info("Running mesh verification")
			return bootstrapPkg.VerifyMesh(cmd.Context())
		},
	}
}

func addClusterFlags(cmd *cobra.Command) {
	cmd.PersistentFlags().String("kubeconfig", "", "Override kubeconfig path")
	cmd.PersistentFlags().String("context", "", "Override kubeconfig context")
}

// createForceCleanupCommand adds force cleanup command for stuck namespaces
func createForceCleanupCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "force-cleanup-namespaces",
		Short: "Force cleanup stuck terminating namespaces",
		Long:  "Aggressively clean up namespaces stuck in Terminating state",
		RunE: func(cmd *cobra.Command, args []string) error {
			clusterType, _ := cmd.Flags().GetString("cluster")
			if clusterType == "" {
				clusterType = "homelab" // default
			}

			log.Info("🔧 Starting force cleanup of terminating namespaces", "cluster", clusterType)

			// Load configuration
			loader := config.NewLoader()
			cfg, err := loader.LoadConfig(clusterType)
			if err != nil {
				return err
			}

			// Create destroy manager
			isNAS := clusterType == "nas"
			destroyManager, err := destroy.NewManager(cfg, isNAS)
			if err != nil {
				return err
			}

			// Force cleanup namespaces
			return destroyManager.ForceCleanupNamespaces(cmd.Context())
		},
	}

	cmd.Flags().String("cluster", "homelab", "Cluster type (homelab or nas)")
	return cmd
}

// createRecoveryCommand adds recovery and diagnostic commands
func createRecoveryCommand() *cobra.Command {
	recoveryCmd := &cobra.Command{
		Use:   "recovery",
		Short: "Recovery and diagnostic commands",
		Long:  "Diagnose system issues and recover from bootstrap failures",
	}

	// Diagnostic command
	recoveryCmd.AddCommand(&cobra.Command{
		Use:   "diagnose",
		Short: "Diagnose system state",
		Long:  "Perform comprehensive diagnostics to identify system issues",
		RunE: func(cmd *cobra.Command, args []string) error {
			log.Info("🔍 Starting system diagnostics...")

			// Load configuration for both clusters
			loader := config.NewLoader()
			cfg, err := loader.LoadConfig("homelab")
			if err != nil {
				// Try to load individual configs
				cfg = &config.Config{}
				if homelabCfg, err := loader.LoadConfig("homelab"); err == nil {
					cfg.Homelab = homelabCfg.Homelab
				}
				if nasCfg, err := loader.LoadConfig("nas"); err == nil {
					cfg.NAS = nasCfg.NAS
				}
			}

			// Create diagnostic manager
			diagnosticManager, err := recovery.NewDiagnosticManager(cfg, false)
			if err != nil {
				return fmt.Errorf("failed to create diagnostic manager: %w", err)
			}

			// Run diagnostics
			results, err := diagnosticManager.DiagnoseSystem(cmd.Context())
			if err != nil {
				return fmt.Errorf("diagnostics failed: %w", err)
			}

			// Print results
			diagnosticManager.PrintDiagnostics(results)

			return nil
		},
	})

	return recoveryCmd
}
