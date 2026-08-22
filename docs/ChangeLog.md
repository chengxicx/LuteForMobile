# Bug Fixes
- Add HTTP Basic Authentication support so the client can read books from servers protected by Basic Auth (e.g. the production `metaman.dpdns.org` deployment). Previously all API requests lacked auth, so such servers returned HTTP 401 and the book list/reader failed to load.
- Include Basic Auth credentials in the server health check (`/info`) so a protected server is no longer misreported as unreachable.

# New Feature
- Settings screen now lets you configure a Username and Password (Basic Auth) for the lute server.

# Other Changes
-
