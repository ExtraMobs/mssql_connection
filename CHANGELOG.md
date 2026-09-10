# Changelog

All notable changes to this project will be documented in this file.
## [0.0.1]

### Added
- Active Dart FFI + FreeTDS packaging for Windows x64. Other platform files are archived under `todo/`, with progress in `TODO.md`; they are not registered or shipped as supported platforms.
- Exclusive callback transactions through `transaction((tx) async { ... })` and independent sessions through `MssqlConnection()`.
- Bulk insertion API using FreeTDS BCP for high-throughput inserts.
- Parameterized queries (via `sp_executesql`) to reduce SQL injection risk.

### Changed
- Added `trustServerCertificate` (default false): explicit opt-in skips certificate chain/hostname checks while retaining mandatory TLS. Manual CA/hostname configuration remains untested end to end with a trusted certificate.
- SQL operations return `SqlResponse` with `resultSets` and `totalAffectedRows`.
- Replaced platform-specific method channels/ODBC paths with a single FFI pipeline for consistent behavior.
- Connections require TLS 1.2+, trusted certificates and hostname validation; native loading uses bundle paths.
- Windows and Android libraries rebuilt with static OpenSSL 3.5.8; Android ELF load segments aligned for 16 KB pages.

### Fixed
- More robust Unicode/large text handling and consistent Base64 encoding for binary columns.
- Empty RPC values remain distinct from NULL; MONEY/DECIMAL preserve exact values as strings.
- Validated identifiers, BCP column order and integer widths; native failures invalidate sessions instead of returning partial results.
- Corrected native callback cancellation, ABI signatures and LOGINREC ownership; added query timeouts and result limits.
- Removed example password logging and embedded connection credentials.

### Breaking
- `getData`/`writeData` return `SqlResponse`, not JSON strings.
- Manual `beginTransaction`/`commit`/`rollback` methods throw `UnsupportedError`; migrate to `transaction`. Reconnection after native failures is explicit.
- `DateTime` parameters use binary `datetimeoffset(7)`, preserving the Dart instant, offset and microseconds. Exact decimal and monetary results are strings.
- Updated Dart code requires the patched native libraries; old binaries are rejected.

## [2.0.2]

### Changed
* Improved handling of affected row count for UPDATE statements returning 0 rows on Windows.
* Enhanced type parsing in the default case for the Windows platform to support long text and binary fields.
* Suppressed warnings related to jcifs and org.ietf.jgss classes during build.
* Addressed R8 build issues, including missing classes and binary type resolution.
* Fixed UTF-8 decoding inconsistencies when reading large text fields on Windows.

## [2.0.1]

### Updated
- Adjusted environment configuration for improved compatibility with a broader range of Flutter projects.

## [2.0.0]

### Added
- Gradle 8 support for improved compatibility with the latest Android tools.
- Windows support using ODBC for seamless database connectivity on Windows platforms.

### Updated
- Enhanced error handling with a custom exception mechanism for better debugging and user feedback.
- Performance optimization and memory improvements.

### Fixed
- Resolved issues with error message parsing to ensure consistent error details in logs.

## [1.1.3]

### Fixed
- Bug fixes related to the execution of stored procedures, improving reliability.

## [1.1.2]

### Updated
- Changed the `bit` SQL type handling to `Integer` for improved type compatibility and consistency.

## [1.1.1]

### Updated
- Modified the timestamp format from milliseconds to a date string for better readability and interoperability.

## [1.1.0]

### Optimized
- Plugin refactoring: Converted codebase from Java to Kotlin, resulting in significant performance enhancements and cleaner code structure.

## [1.0.3]

### Updated
- Improved code documentation for better developer understanding and usage guidelines.

## [1.0.2]

### Updated
- Enhanced project documentation to include detailed setup and usage instructions.

## [1.0.1]

### Added
- Initial release of the Flutter plugin for connecting to Microsoft SQL Server databases.
- Support for customizable database connection parameters.
- Functionality to execute SQL queries and retrieve results in JSON format.
- Support for database write operations (insert, update, delete) with transaction management.
- Automatic reconnection handling for robust connectivity during connection interruptions.
- Configurable timeout settings for managing database connection response times.

[2.0.2]: https://github.com/Hiteshdon/mssql_connection.git
[3.0.0]: https://github.com/Hiteshdon/mssql_connection.git
