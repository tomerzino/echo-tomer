# Changelog

## 1.0.0 (2026-05-05)


### Features

* add cross-references to DEPLOYMENT.md ([281010c](https://github.com/tomerzino/echo-tomer/commit/281010c130cb757b313bf77a59d6e1d2297b20b5))
* add cross-references to DEPLOYMENT.md ([9b82a89](https://github.com/tomerzino/echo-tomer/commit/9b82a8993738b9079714c2d02b38b4ac0d082787))
* add Gateway API resource for local Kind cluster ([094f5e3](https://github.com/tomerzino/echo-tomer/commit/094f5e30fad0d0c04f32f472e451470ee31300a2))
* add Helm common chart with deployment, service, and serviceaccount ([58cc0f2](https://github.com/tomerzino/echo-tomer/commit/58cc0f2e90452e8b8a9ee545c74a3665328553fd))
* add integration test job to PR workflow ([cf3a71c](https://github.com/tomerzino/echo-tomer/commit/cf3a71c118cc0f4f0e7006bd72c1cae7daa4b4c7))
* add Makefile, graceful shutdown, Go 1.25.9, and expanded docs ([f116950](https://github.com/tomerzino/echo-tomer/commit/f1169507c6a2a7f17f5b3121982b0a8b7df9d33f))
* add multi-stage Dockerfile with scratch base image ([65c0d8e](https://github.com/tomerzino/echo-tomer/commit/65c0d8e8c82d1c91f0b98705bc9da25a63a94ed4))
* add ping-pong deploy configuration using common chart ([a3786a3](https://github.com/tomerzino/echo-tomer/commit/a3786a31bac6b849013d39ef1d17edf3de0770ca))
* add PR validation workflow with test, lint, scan, and helm lint ([151e290](https://github.com/tomerzino/echo-tomer/commit/151e290551730f6a62e86a9802ce3517415261b8))
* add release workflow with multi-arch builds, Trivy scanning, binary releases, and SBOM ([a770703](https://github.com/tomerzino/echo-tomer/commit/a77070388b99ddc1450cde64f564952bd82b18c7))
* add release-please workflow for automated versioning ([b38fd8e](https://github.com/tomerzino/echo-tomer/commit/b38fd8e26bb40d7108c41c12d19edced527a6196))
* add secret, externalsecret, and httproute templates to common chart ([67621a6](https://github.com/tomerzino/echo-tomer/commit/67621a69eb36bf7fc1d66ba1e43d322aaaee33ce))
* add SOPS encrypted secrets for ping-pong service ([388c582](https://github.com/tomerzino/echo-tomer/commit/388c582d4b2fba7ff956e0f832d4e5c1de09ead5))


### Bug Fixes

* handle unchecked error returns for file.Close and fmt.Fprint ([e27bac9](https://github.com/tomerzino/echo-tomer/commit/e27bac95e5bcfb9fcb5a818573d74af3cc7f1476))
* handle unchecked error returns in authMiddleware ([a6b450a](https://github.com/tomerzino/echo-tomer/commit/a6b450a900b715208a6384abb6e76639230925eb))
* resolve go vet warning and make govulncheck non-blocking for stdlib vulns ([1dc6fc5](https://github.com/tomerzino/echo-tomer/commit/1dc6fc59b38d719139d27368e0ca53d6ea1f0fdc))
* upgrade Go from 1.24 to 1.25 to resolve stdlib CVEs ([63609c1](https://github.com/tomerzino/echo-tomer/commit/63609c188936af68a33050f0c77cd4626ecbdaec))
* upgrade golangci-lint to v2 for Go 1.25 compatibility ([430ce38](https://github.com/tomerzino/echo-tomer/commit/430ce385144d1dc8fdfc49e16cef7e42efa57a3d))
