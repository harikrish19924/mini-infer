package gateway

import "net/http"

// Model is a model the gateway serves, as clients name it.
type Model struct {
	Name        string // vLLM's --served-model-name
	MaxModelLen int    // vLLM's --max-model-len: prompt + output tokens must fit in it
	Endpoint    string // vLLM base URL, e.g. http://qwen-0-5b-vllm:8000 (one backend until step 7)
}

// api holds what the handlers need. Handlers are methods on it, so tests can
// build one with any model list.
type api struct {
	models []Model          // in config order, for GET /v1/models
	byName map[string]Model // for lookups during validation
	client *http.Client     // shared by every upstream request, so connections are reused
}

func newAPI(models []Model) *api {
	a := &api{
		models: models,
		byName: make(map[string]Model, len(models)),
		client: newUpstreamClient(),
	}
	for _, m := range models {
		a.byName[m.Name] = m
	}
	return a
}
