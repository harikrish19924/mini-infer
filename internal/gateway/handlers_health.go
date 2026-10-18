package gateway

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// healthz reports only that this process is up; it must never check vLLM,
// or a vLLM outage would make Kubernetes restart every gateway pod.
func healthz(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}
