BIN      := bin
BINARIES := gateway loadgen

.PHONY: all build test vet fmt lint clean $(BINARIES)

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

session:   ## make session IP=1.2.3.4
	./scripts/new-session.sh $(IP) --with-vllm

stop:
	./scripts/new-session.sh stop
