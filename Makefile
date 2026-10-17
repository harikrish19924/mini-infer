BIN      := bin
BINARIES := gateway loadgen

# Which cluster deploy/bench talk to: local (k3d, weeks 1-10) or e2e (E2E GPU node, weeks 11-13)
ENV ?= local

ifeq ($(ENV),local)
KUBE_ARGS      := --context k3d-tinyinfer
HELM_ARGS      := --kube-context k3d-tinyinfer
KO_DOCKER_REPO ?= localhost:5111
KO_PLATFORM    := linux/arm64
else ifeq ($(ENV),e2e)
KUBE_ARGS      := --kubeconfig $(HOME)/.kube/tinyinfer.yaml
HELM_ARGS      := --kubeconfig $(HOME)/.kube/tinyinfer.yaml
KO_DOCKER_REPO ?= ghcr.io/harikrish19924/mini-infer
KO_PLATFORM    := linux/amd64
else
$(error ENV must be local or e2e, got '$(ENV)')
endif

CHART := deploy/helm/tinyinfer
KO    := KO_DOCKER_REPO=$(KO_DOCKER_REPO) ko build --base-import-paths --platform=$(KO_PLATFORM)

.PHONY: all build test vet fmt lint clean $(BINARIES) \
        local-up local-down deploy bench session stop

all: build

build: $(BINARIES)

$(BINARIES):
	go build -o $(BIN)/$@ ./cmd/$@

test:
	go test -race ./...

vet:
	go vet ./...

fmt:
	gofmt -s -w .

clean:
	rm -rf $(BIN)

# --- local k3d mirror -------------------------------------------------------

local-up:   ## create/start the k3d cluster (fake GPUs, RuntimeClass, monitoring, registry)
	./scripts/local-up.sh

local-down: ## delete the k3d cluster and its registry
	./scripts/local-up.sh down

# --- both clusters ----------------------------------------------------------

# make deploy [ENV=local|e2e]
# Builds images with ko, pushes them (local registry, or GHCR for e2e) and installs
# the chart with values-$(ENV).yaml. The chart receives the image refs as
# images.gateway and images.operator (the operator once operator/go.mod exists).
deploy:
	@test -f $(CHART)/Chart.yaml || { echo "no Helm chart at $(CHART) yet (phase 4)"; exit 1; }
	@test -f $(CHART)/values-$(ENV).yaml || { echo "missing $(CHART)/values-$(ENV).yaml"; exit 1; }
	@command -v ko >/dev/null || { echo "ko not found (brew install ko)"; exit 1; }
	@set -e; \
	gateway=$$($(KO) ./cmd/gateway); \
	set -- --set images.gateway=$$gateway; \
	if [ -f operator/go.mod ]; then \
	  operator=$$(cd operator && $(KO) ./cmd); \
	  set -- "$$@" --set images.operator=$$operator; \
	fi; \
	helm $(HELM_ARGS) upgrade --install tinyinfer $(CHART) \
	  -n tinyinfer --create-namespace \
	  -f $(CHART)/values-$(ENV).yaml "$$@" --wait --timeout 30m; \
	kubectl $(KUBE_ARGS) -n tinyinfer get pods

# make bench SCENARIO=sweep [ENV=local|e2e]   (details: scripts/bench.sh)
bench:
	@test -n "$(SCENARIO)" || { echo "usage: make bench SCENARIO=<name> [ENV=local|e2e]"; exit 1; }
	KO_DOCKER_REPO=$(KO_DOCKER_REPO) ./scripts/bench.sh $(ENV) $(SCENARIO)

# --- E2E sessions (weeks 11-13) ---------------------------------------------

session:   ## make session IP=1.2.3.4
	./scripts/new-session.sh $(IP) --with-vllm

stop:
	./scripts/new-session.sh stop
