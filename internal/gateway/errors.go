package gateway

import (
	"github.com/gin-gonic/gin"

	"github.com/harikrish19924/mini-infer/internal/openai"
)

// writeError sends an OpenAI-style error body, which OpenAI SDKs know how to parse.
func writeError(c *gin.Context, e *apiError) {
	body := openai.ErrorResponse{Error: openai.Error{Message: e.message, Type: e.errType}}
	if e.param != "" {
		body.Error.Param = &e.param
	}
	if e.code != "" {
		body.Error.Code = &e.code
	}
	c.AbortWithStatusJSON(e.status, body)
}
