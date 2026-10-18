package gateway

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// registerRoutes is the gateway's whole route table.
func registerRoutes(engine *gin.Engine, a *api) {
	engine.POST("/v1/chat/completions", a.chatCompletions)
	engine.POST("/v1/completions", a.completions)
	engine.GET("/v1/models", a.listModels)
	engine.GET("/healthz", healthz)
	engine.GET("/metrics", gin.WrapH(promhttp.Handler()))

	engine.NoRoute(func(c *gin.Context) {
		writeError(c, &apiError{
			status:  http.StatusNotFound,
			errType: "invalid_request_error",
			message: "unknown route " + c.Request.URL.Path,
		})
	})
	engine.NoMethod(func(c *gin.Context) {
		writeError(c, &apiError{
			status:  http.StatusMethodNotAllowed,
			errType: "invalid_request_error",
			message: "method " + c.Request.Method + " not allowed on " + c.Request.URL.Path,
		})
	})
}
