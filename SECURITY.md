# Security

IP Browser's promise is narrow: websites opened in it see only your server's address, and nothing of the browser's traffic leaves another way. A way around that — a leak past the server, another profile's traffic on this server, a key or management access that outlives its revocation — is a security bug.

Please report it privately through GitHub's **Report a vulnerability** (Security tab of this repository), not in a public issue. Include the iOS version, the build (Settings → About) and, if you can, the leak test's result. We answer within a week.

What is measured and what is not: [docs/LEAKS.md](docs/LEAKS.md). The server side: [docs/SERVER.md](docs/SERVER.md).
