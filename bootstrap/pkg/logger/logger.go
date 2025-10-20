package logger

import (
	"io"
	"os"

	"github.com/charmbracelet/log"
)

// SetupLogger configures a beautiful logger for the application
func SetupLogger() {
	// Create a styled logger
	logger := log.NewWithOptions(os.Stderr, log.Options{
		ReportCaller:    false,
		ReportTimestamp: true,
		Level:           log.InfoLevel,
	})

	// Set as default logger
	log.SetDefault(logger)
}

// SetLevel sets the logging level
func SetLevel(level string) {
	switch level {
	case "debug":
		log.SetLevel(log.DebugLevel)
	case "info":
		log.SetLevel(log.InfoLevel)
	case "warn":
		log.SetLevel(log.WarnLevel)
	case "error":
		log.SetLevel(log.ErrorLevel)
	default:
		log.SetLevel(log.InfoLevel)
	}
}

// SetupTUILogger configures logging for TUI mode - redirects all log output to a file
func SetupTUILogger(logFile io.Writer) {
	// For infrastructure/bootstrap tools, always use debug level when logging to file
	// Platform engineers need detailed logs for troubleshooting complex operations
	level := log.DebugLevel
	
	// Create a logger that outputs to the provided writer (file)
	logger := log.NewWithOptions(logFile, log.Options{
		ReportCaller:    false,
		ReportTimestamp: true,
		Level:           level,
	})

	// Set as default logger
	log.SetDefault(logger)
}
