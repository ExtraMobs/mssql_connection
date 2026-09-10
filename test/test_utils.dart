import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:sql_server_wrapper/mssql_connection.dart';

void requireTempDbConfig() {
  final env = Platform.environment;
  if (env['RUN_DB_TESTS'] != '1' ||
      env['MSSQL_SERVER']?.isNotEmpty != true ||
      env['MSSQL_USER']?.isNotEmpty != true ||
      ![
        env['MSSQL_PASS'],
        env['MSSQL_PASSWORD'],
      ].any((p) => p?.isNotEmpty == true)) {
    throw StateError(
      'Temporary database tests require RUN_DB_TESTS=1, '
      'MSSQL_SERVER, MSSQL_USER and MSSQL_PASSWORD (or MSSQL_PASS).',
    );
  }
}

String _uniqueDbName([String prefix = 'Test']) {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final rnd = Random().nextInt(0xFFFFFF);
  return '${prefix}_${ts}_$rnd';
}

Future<void> runWithClientAndTempDb(
  Future<void> Function(MssqlConnection client, String dbName) body,
) async {
  requireTempDbConfig();
  final server = Platform.environment['MSSQL_SERVER']!;
  final username = Platform.environment['MSSQL_USER']!;
  final password =
      Platform.environment['MSSQL_PASS'] ??
      Platform.environment['MSSQL_PASSWORD']!;

  // Parse server into ip and port (default 1433)
  final parts = server.split(':');
  final ip = parts.isNotEmpty ? parts.first : '127.0.0.1';
  final port = parts.length > 1 ? parts[1] : '1433';

  final client = MssqlConnection.getInstance();
  final ok = await client.connect(
    ip: ip,
    port: port,
    databaseName: 'master',
    username: username,
    password: password,
  );
  if (!ok) {
    throw StateError('Failed to connect to $server as $username');
  }

  final dbName = _uniqueDbName('Test');
  try {
    await client.execute('CREATE DATABASE [$dbName]');
    await client.execute('USE [$dbName]');
    await body(client, dbName);
  } finally {
    try {
      await client.execute('USE master');
      await client.execute(
        'ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE',
      );
      await client.execute('DROP DATABASE [$dbName]');
    } catch (_) {}
    await client.disconnect();
  }
}

// Compat layer so tests can call client.execute/query/executeParams with
// a MssqlConnection instance.
extension _TestClientCompat on MssqlConnection {
  Future<SqlResponse> execute(String sql) => writeData(sql);
  Future<SqlResponse> query(String sql) => getData(sql);
  Future<SqlResponse> executeParams(String sql, Map<String, dynamic> params) =>
      writeDataWithParams(sql, params);
}

List<Map<String, dynamic>> parseRows(SqlResponse response) {
  if (response.error != null) throw SQLException(response.error!);
  if (response.resultSets.isEmpty) return [];
  final set = response.resultSets.single;
  return [
    for (final row in set.rows)
      Map<String, dynamic>.fromIterables(set.columns, row),
  ];
}

int affectedCount(SqlResponse response) {
  if (response.error != null) throw SQLException(response.error!);
  return response.totalAffectedRows;
}

/// A reusable temp-database harness for running many tests within a single DB.
///
/// This avoids the overhead of creating/dropping a database for each test case
/// when scaling up to dozens of cases per mode. Use setUpAll/tearDownAll in
/// your test group to initialize and dispose this harness once per group.
class TempDbHarness {
  late final MssqlConnection client;
  late final String dbName;

  Future<void> init() async {
    client = MssqlConnection.getInstance();
    await reconnect(database: 'master');
    dbName = _uniqueDbName('Bulk');
    await client.execute('CREATE DATABASE [$dbName]');
    await client.execute('USE [$dbName]');
  }

  Future<void> reconnect({String? database}) async {
    requireTempDbConfig();
    final server = Platform.environment['MSSQL_SERVER']!;
    final username = Platform.environment['MSSQL_USER']!;
    final password =
        Platform.environment['MSSQL_PASS'] ??
        Platform.environment['MSSQL_PASSWORD']!;
    final parts = server.split(':');
    final ip = parts.isNotEmpty ? parts.first : '127.0.0.1';
    final port = parts.length > 1 ? parts[1] : '1433';

    final ok = await client.connect(
      ip: ip,
      port: port,
      databaseName: database ?? dbName,
      username: username,
      password: password,
      caFile: Platform.environment['MSSQL_CA_FILE'] ?? 'system',
      certificateHostname: Platform.environment['MSSQL_CERTIFICATE_HOSTNAME'],
    );
    if (!ok) {
      throw StateError('Failed to connect to $server as $username');
    }
  }

  Future<void> dispose() async {
    try {
      if (!client.isConnected) await reconnect(database: 'master');
      await client.execute('USE master');
      await client.execute(
        'ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE',
      );
      await client.execute('DROP DATABASE [$dbName]');
    } catch (_) {}
    await client.disconnect();
  }

  Future<SqlResponse> execute(String sql) => client.execute(sql);
  Future<SqlResponse> query(String sql) => client.query(sql);
  Future<SqlResponse> executeParams(String sql, Map<String, dynamic> params) =>
      client.executeParams(sql, params);

  /// Drops the table if it exists and recreates it using the provided CREATE TABLE statement.
  Future<void> recreateTable(String createTableSql) async {
    // Attempt to extract table name from CREATE TABLE statement to drop it first.
    // Expect pattern like: CREATE TABLE [schema.]Name ( ... )
    final match = RegExp(
      r'CREATE\s+TABLE\s+([^\s(]+)',
      caseSensitive: false,
    ).firstMatch(createTableSql);
    if (match != null) {
      final tableIdent = match.group(1)!;
      // Build raw (unbracketed) two-part name for OBJECT_ID and a bracketed form for DROP TABLE
      String raw = tableIdent.replaceAll('[', '').replaceAll(']', '');
      if (!raw.contains('.')) raw = 'dbo.$raw';
      final parts = raw.split('.');
      final bracketed = '[${parts[0]}].[${parts[1]}]';
      await execute(
        "IF OBJECT_ID(N'$raw', N'U') IS NOT NULL DROP TABLE $bracketed",
      );
    }
    await execute(createTableSql);
  }
}

// Centralized test DB configuration
class TestDbConfig {
  final String ip;
  final int port;
  final String databaseName;
  final String username;
  final String password;

  const TestDbConfig({
    required this.ip,
    required this.port,
    required this.databaseName,
    required this.username,
    required this.password,
  });

  static TestDbConfig fromEnv() {
    final env = Platform.environment;
    return TestDbConfig(
      ip: env['MSSQL_IP']?.trim().isNotEmpty == true
          ? env['MSSQL_IP']!.trim()
          : '127.0.0.1',
      port: int.tryParse(env['MSSQL_PORT'] ?? '') ?? 1433,
      databaseName: env['MSSQL_DB']?.trim().isNotEmpty == true
          ? env['MSSQL_DB']!.trim()
          : 'master',
      username: env['MSSQL_USER']?.trim() ?? '',
      password: env['MSSQL_PASSWORD']?.trim() ?? '',
    );
  }

  static final TestDbConfig current = TestDbConfig.fromEnv();
}
