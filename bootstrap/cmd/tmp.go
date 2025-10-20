package main
import (
    "fmt"
    "github.com/fluxcd/flux2/v2/pkg/manifestgen/install"
)
func main() {
    manif, err := install.Generate(install.Options{Namespace:"flux-system", Version:"latest", Components: []string{"source-controller"}}, "")
    if err != nil { panic(err) }
    fmt.Println(len(manif.Content))
}
