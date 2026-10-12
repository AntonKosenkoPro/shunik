| Index | Requirement                                                                                                                                                             | Comment |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| U1    | Should have minimalistic design                                                                                                                                         |         |
| U2    | Should support Dark and light theme                                                                                                                                     |         |
| U3    | Should work correctly offline (after the mandatory sign-in; anonymous offline use is removed)                                                                                                                            |         |
| U4    | Should support localization (English and Russian at least)                                                                                                               |         |
| U5    | Should be in strict compliance with Apple Human Interface Guidelines                                                                                                     |         |
| R1    | Should store auth data securely (no direct password store for instance)                                                                                                 |         |
| S1    | Should use most mainstream technologies (e.g. PostgreSQL for SQL DB, Kafka for MQ, etc.)                                                                                |         |
| S2    | Should use the native UI SDK whenever possible                                                                                                                           |         |
| S3    | Should target to 100% test coverage                                                                                                                                     |         |
| S4    | Entire app should be able to run locally and in a cloud                                                                                                                 |         |
| S5    | Source code should be minimal and standardized, following modern best practices. Every iteration should include a revision process that preserves this requirement.      |         |
| S6    | Code linters and analyzers should enforce code quality.                                                                                                                  |         |
| S6    | Tests and linters should run on every pull request as mandatory checks (provider-neutral: GitHub Actions or Xcode Cloud status checks).                       |         |
| S7    | `AGENTS.md` should provide an effective entrypoint to all necessary information and context for AI agents.                                                               | ✅ `AGENTS.md` (concise entrypoint) + `docs/project-context.md` (canonical context) + `openspec/README.md` |
| S8    | There should be logging across all parts of the system                                                                                                                  |         |
| S9    | There should be Figma-compatible Design Tokens to store all suitable design variable                                                                                    |         |
| S10   | There should be OpenAPI documentation for every backend API                                                                                                             | ✅ `backend/api/openapi.yaml` (OpenAPI 3.0) |
| +1    | Should work without website                                                                                                                                             |         |
| +2    | Should work on iOS 18+ and support correctly all supported devices (correct layout, feature support)                                                                    |         |
| +3    | Backend should use Golang                                                                                                                                               |         |
| +4    | Mobile app should use Swift                                                                                                                                             |         |

  
FURPS+ - Functionality, Usability, Reliability, Performance, Supportability + Restrictions
