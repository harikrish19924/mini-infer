CLUSTER  ?= tinyinfer
BIN      := bin
BINARIES := gateway fakemodel loadgen

.PHONY: all build test vet fmt lint clean dev dev-down $(BINARIES)

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

# Bring up the whole stack on a local k3d cluster.
# Grows as phases land: images and the Helm install are added in phase 4.
dev:
	k3d cluster list $(CLUSTER) >/dev/null 2>&1 || k3d cluster create --config deploy/k3d/cluster.yaml

dev-down:
	k3d cluster delete $(CLUSTER)
