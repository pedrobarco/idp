FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /hello-app .

FROM alpine:3.19
COPY --from=build /hello-app /hello-app
EXPOSE 8080
ENTRYPOINT ["/hello-app"]
