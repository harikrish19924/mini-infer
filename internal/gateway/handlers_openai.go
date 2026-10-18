package gateway

import (
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/harikrish19924/mini-infer/internal/openai"
)

func (a *api) chatCompletions(c *gin.Context) { a.handleGeneration(c, a.parseChat) }

func (a *api) completions(c *gin.Context) { a.handleGeneration(c, a.parseCompletion) }

// handleGeneration reads the body, validates it with parse, and hands a valid
// request to the proxy. Bad requests stop here, before they reach a GPU.
func (a *api) handleGeneration(c *gin.Context, parse func([]byte) (*proxyRequest, *apiError)) {
	body, err := io.ReadAll(http.MaxBytesReader(c.Writer, c.Request.Body, maxBodyBytes))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(c, &apiError{
				status:  http.StatusRequestEntityTooLarge,
				errType: "invalid_request_error",
				message: fmt.Sprintf("request body is larger than %d MiB", maxBodyBytes>>20),
			})
			return
		}
		writeError(c, badRequest("", "could not read request body: %v", err))
		return
	}

	req, apiErr := parse(body)
	if apiErr != nil {
		writeError(c, apiErr)
		return
	}
	a.proxy(c, req)
}

// proxy will stream the request to a vLLM replica (phase 2, step 3).
func (a *api) proxy(c *gin.Context, req *proxyRequest) {
	writeError(c, &apiError{
		status:  http.StatusNotImplemented,
		errType: "server_error",
		message: "proxying to vLLM is not implemented yet",
	})
}

// listModels answers from the gateway's own model list, not from vLLM.
func (a *api) listModels(c *gin.Context) {
	list := openai.ModelList{Object: "list", Data: make([]openai.Model, 0, len(a.models))}
	for _, m := range a.models {
		list.Data = append(list.Data, openai.Model{ID: m.Name, Object: "model", OwnedBy: "tinyinfer"})
	}
	c.JSON(http.StatusOK, list)
}
