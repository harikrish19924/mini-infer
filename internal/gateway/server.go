// Package gateway is the gateway's HTTP layer: the gin engine, its routes and
// handlers. It is the only package that imports gin; the logic it calls
// (internal/router, ratelimit, metering, ...) stays framework-free.
package gateway

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// Server is the gateway's HTTP server.
type Server struct {
	http *http.Server
}

// New builds the gin engine, registers every route and returns a Server
// that will listen on addr and serve the given models.
func New(addr string, models []Model) *Server {
	gin.SetMode(gin.DebugMode)
	return &Server{
		http: &http.Server{
			Addr:    addr,
			Handler: newEngine(models),
		},
	}
}

// newEngine builds the gin engine with its middleware and routes.
// Tests call it directly to exercise the handlers without a network.
func newEngine(models []Model) *gin.Engine {
	engine := gin.New()
	engine.Use(gin.Recovery())
	engine.HandleMethodNotAllowed = true
	registerRoutes(engine, newAPI(models))
	return engine
}

// Run listens and serves until the server fails or is shut down.
func (s *Server) Run() error {
	return s.http.ListenAndServe()
}
