# Security policy

This repository is unaudited alpha software. Do not deploy it as an unreviewed
production consensus boundary. Report vulnerabilities privately to
`security@reuna.io` rather than opening a public issue.

## Review boundary

Treat the CometBFT peer, every transaction and every ABCI request as untrusted.
The priority surfaces are protobuf decoding, frame/message bounds, request
ordering, deterministic application responses, restart/replay, durable state
commitment and agreement between socket and gRPC transports.

This library supplies ABCI plumbing; it does not make an application state
machine deterministic, durable or safe. Application authorization, storage,
snapshot validation and upgrade policy remain the caller's responsibility.
