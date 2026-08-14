# Enforce MCP OAuth issuer binding

## Summary

- validate authorization response `iss` when RFC 9207 requires or supplies it
- send DCR `application_type` with a documented default
- bind configured and dynamically registered client credentials to an exact authorization-server issuer
- bind stored access tokens to their issuing authorization server

## Specification coverage

- `basic/authorization/authorization-server-discovery#authorization-server-location`
- `basic/authorization/client-registration#client-registration-priority`
- `basic/authorization/client-registration#client-id-metadata-documents`
- `basic/authorization/client-registration#authorization-server-binding`
- RFC 9207 authorization response issuer validation

## Compatibility

The existing OAuth flow, public authorizer type, token storage protocol, and endpoint validation stay
in place. New configuration parameters have defaults. Stored tokens without the new issuer field
remain decodable and use the earlier URL field for compatibility.

This unit should remain independent of per-request-metadata transport behavior even though it is
physically stacked after the wire-model branch.

## Review guide

Review credential and token provenance as one state machine: configured credentials, CIMD credentials,
DCR credentials, issuer changes, refresh, and persistent token reload. Then review exact-string issuer
comparisons and the RFC 9207 redirect checks.

## Testing

- exact and mismatched authorization response issuer
- DCR application type
- advertised-server selection for preconfigured, dynamically registered, and CIMD credentials
- exact persisted-token binding before and after discovery
- issuer changes during challenge handling never send the earlier issuer's refresh token
- transient and issuer-scoped DCR attempts
- warnings-as-errors public documentation build
- `OAuthAuthorizerTests`: 21 tests passed on macOS
