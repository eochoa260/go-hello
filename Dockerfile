# BUILD
FROM golang:1.14 as build

COPY . .

RUN go build -o /main

# DEPLOY
FROM gcr.io/distroless/base-debian10

WORKDIR /

COPY --from=build /main /main

EXPOSE 8080

user nonroot:nonroot

ENTRYPOINT ["./main"]
