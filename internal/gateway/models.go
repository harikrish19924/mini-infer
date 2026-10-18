package gateway

// Model is a model the gateway serves, as clients name it.
type Model struct {
	Name        string // vLLM's --served-model-name
	MaxModelLen int    // vLLM's --max-model-len: prompt + output tokens must fit in it
}

// api holds what the handlers need. Handlers are methods on it, so tests can
// build one with any model list.
type api struct {
	models []Model          // in config order, for GET /v1/models
	byName map[string]Model // for lookups during validation
}

func newAPI(models []Model) *api {
	a := &api{models: models, byName: make(map[string]Model, len(models))}
	for _, m := range models {
		a.byName[m.Name] = m
	}
	return a
}
