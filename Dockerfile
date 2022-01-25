ARG BUILDARCH=amd64
ARG TARGETARCH=amd64

### Front-end
FROM node:16 AS front-end

WORKDIR /app/ui-build

COPY ui/package.json .
COPY ui/package-lock.json .
RUN npm i
COPY ui .
RUN npm run build


### Base builder image for native builds architecture
FROM golang:1.16-alpine AS builder-native-base
ENV CGO_ENABLED=1 GOOS=linux
RUN apk add libpcap-dev gcc g++ make bash perl-utils


### Intermediate builder image for from AMD64 to AMD64 native builds
FROM builder-native-base AS builder-from-amd64-to-amd64
ENV GOARCH=amd64


### Intermediate builder image for from AMD64 to AMD64 native builds
FROM builder-native-base AS builder-from-arm64v8-to-arm64v8
ENV GOARCH=arm64v8


### Builder image for from AMD64 to ARM64 cross-compilation
FROM up9inc/linux-arm64-musl-go-libpcap AS builder-from-amd64-to-arm64v8
ENV CGO_ENABLED=1 GOOS=linux
ENV GOARCH=arm64 CGO_CFLAGS="-I/work/libpcap"


### Final builder image where the build happens
ARG BUILDARCH=amd64
ARG TARGETARCH=amd64
FROM builder-from-${BUILDARCH}-to-${TARGETARCH} AS builder

# Move to agent working directory (/agent-build).
WORKDIR /app/agent-build

COPY agent/go.mod agent/go.sum ./
COPY shared/go.mod shared/go.mod ../shared/
COPY tap/go.mod tap/go.mod ../tap/
COPY tap/api/go.mod ../tap/api/
COPY tap/extensions/amqp/go.mod ../tap/extensions/amqp/
COPY tap/extensions/http/go.mod ../tap/extensions/http/
COPY tap/extensions/kafka/go.mod ../tap/extensions/kafka/
COPY tap/extensions/redis/go.mod ../tap/extensions/redis/
RUN go mod download
# cheap trick to make the build faster (as long as go.mod did not change)
RUN go list -f '{{.Path}}@{{.Version}}' -m all | sed 1d | grep -e 'go-cache' | xargs go get

# Copy and build agent code
COPY shared ../shared
COPY tap ../tap
COPY agent .

ARG COMMIT_HASH
ARG GIT_BRANCH
ARG BUILD_TIMESTAMP
ARG SEM_VER=0.0.0

WORKDIR /app/agent-build

RUN go build -ldflags="-extldflags=-static -s -w \
    -X 'mizuserver/pkg/version.GitCommitHash=${COMMIT_HASH}' \
    -X 'mizuserver/pkg/version.Branch=${GIT_BRANCH}' \
    -X 'mizuserver/pkg/version.BuildTimestamp=${BUILD_TIMESTAMP}' \
    -X 'mizuserver/pkg/version.SemVer=${SEM_VER}'" -o mizuagent .


### The shipped image
ARG TARGETARCH=amd64
FROM ${TARGETARCH}/busybox:latest

WORKDIR /app

# Copy binary and config files from /build to root folder of scratch container.
COPY --from=builder ["/app/agent-build/mizuagent", "."]
COPY --from=front-end ["/app/ui-build/build", "site"]
COPY --from=front-end ["/app/ui-build/build-ent", "site-standalone"]

# gin-gonic runs in debug mode without this
ENV GIN_MODE=release

# this script runs both apiserver and passivetapper and exits either if one of them exits, preventing a scenario where the container runs without one process
ENTRYPOINT "/app/mizuagent"
