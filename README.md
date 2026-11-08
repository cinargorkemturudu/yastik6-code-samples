# Yastık6: code samples

Selected source files from [Yastık6](https://github.com/cinargorkemturudu/Yastik6-Portfolio-Showcase), a privacy-first portfolio tracker for gold, currencies, stocks and crypto that I built on my own: a Flutter app and the .NET 10 REST backend it calls.

These are **excerpts, not a buildable project**. Paths match the real repositories, but configuration, generated files and secrets are left out. Everything here is my own code. The architecture write-up and a demo video are linked from the showcase repo above.

## Frontend (Flutter, Riverpod, SQLite)

| If you want to see... | Look at |
|---|---|
| REST integration and error handling | `frontend/lib/data/remote/remote_market_data.dart`, `remote_exceptions.dart` |
| Polling with Riverpod, cache first, keeping the last good data on failure | `frontend/lib/ui/states/live_price_provider.dart`, `lib/domain/models/dtos/market_state.dart` |
| Parallel SQLite reads and a single immutable state payload | `frontend/lib/ui/states/portfolio_provider.dart` |
| The "dumb UI" boundary: domain models mapped to immutable UI models | `frontend/lib/ui/mappers/universal_portfolio_mapper.dart` |
| Work off the main thread: key derivation and AES-GCM in isolates | `frontend/lib/core/crypto_service.dart` |
| Third-party SDKs and a safe restore (Google Drive backup behind a strategy interface) | `frontend/lib/domain/services/cloud_backup_service.dart`, `lib/data/remote/cloud_backup_strategies.dart` |
| Transactional schema migrations and indexes | `frontend/lib/data/local/local_database.dart` |
| Exact decimal money math and FIFO lots | `frontend/lib/domain/services/portfolio_valuator.dart` |
| Overflow-safe text widget | `frontend/lib/ui/utils/app_safe_text.dart` |
| Tests and CI | `frontend/test/`, `frontend/.github/workflows/flutter-test.yml` |

## Backend (ASP.NET Core, .NET 10)

| If you want to see... | Look at |
|---|---|
| Provider failover with alerts and recovery reports | `backend/Yastık6.Api/Infrastructure/BackgroundJobs/PriceSnapshotRefresher.cs` |
| Retry policy (Polly) around every provider call | `backend/Yastık6.Api/Infrastructure/Providers/Base/BasePriceClient.cs` |
| Price validation: rejects zero prices and over-40% spikes, re-anchors after 3 consistent readings | `backend/Yastık6.Api/Application/Features/Prices/PriceShieldValidator.cs` |
| Data retention and downsampling worker | `backend/Yastık6.Api/Infrastructure/BackgroundJobs/DataRetentionWorker.cs` |
| Rate limiting for the public demo API | `backend/Yastık6.Api/Infrastructure/RateLimiting/PublicDemoLimiter.cs` |
| CI/CD: tests gate every deploy | `backend/azure-pipelines.yml` |
| Tests for the above | `backend/Yastık6.Api.Tests/` |

## Honest notes

- Flutter since September 2025; this is one app, built end to end, not a team codebase.
- The app is a personal project and is not published on the app stores.
- Comments are in English. UI labels, error messages and alert texts stay in Turkish because the app itself is Turkish.

Çınar Görkem Türüdü · cinargorkemt@gmail.com
