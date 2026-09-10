import 'dart:async';
import 'mssql_client.dart';
import 'sql_response.dart';
export 'sql_response.dart';

/// Owns a session. getInstance preserves the original shared-instance entry point.
class MssqlConnection {
  static final _instance = MssqlConnection();
  factory MssqlConnection.getInstance() => _instance;
  MssqlConnection();

  MssqlClient? _client;
  Future<void> _tail = Future.value();
  final Object _transactionKey = Object();
  Object? _activeTransaction;
  bool get isConnected => _client?.isConnected == true;

  Future<T> _schedule<T>(
    FutureOr<T> Function() action, {
    bool lifecycle = false,
  }) {
    final token = Zone.current[_transactionKey];
    if (token != null) {
      if (!identical(token, _activeTransaction)) {
        return Future.error(StateError('Transaction has ended'));
      }
      if (lifecycle) {
        return Future.error(
          StateError('Cannot replace a session during a transaction'),
        );
      }
      return Future.sync(action);
    }
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  MssqlClient get _connected {
    final client = _client;
    if (client == null || !client.isConnected) {
      throw StateError('Not connected. Call connect() explicitly.');
    }
    return client;
  }

  /// TLS and certificate verification are mandatory. Supply an absolute PEM CA
  /// path where the platform does not provide an OpenSSL system trust store.
  Future<bool> connect({
    required String ip,
    required String port,
    required String databaseName,
    required String username,
    required String password,
    int timeoutInSeconds = 15,
    int queryTimeoutSeconds = 30,
    String caFile = 'system',
    String? certificateHostname,
    int maxResultRows = 100000,
    int maxResultBytes = 64 * 1024 * 1024,
  }) => _schedule(() async {
    final host = ip.trim(), user = username.trim();
    final portNumber = int.tryParse(port.trim());
    if (host.isEmpty ||
        user.isEmpty ||
        password.isEmpty ||
        portNumber == null ||
        portNumber < 1 ||
        portNumber > 65535 ||
        timeoutInSeconds <= 0) {
      return false;
    }
    final dbName = databaseName.isEmpty
        ? null
        : quoteSqlIdentifier(databaseName);
    final address = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    await _client?.close();
    _client = null;
    final candidate = MssqlClient(
      server: '$address:$portNumber',
      username: user,
      password: password,
      caFile: caFile,
      certificateHostname: certificateHostname,
      queryTimeoutSeconds: queryTimeoutSeconds,
      maxResultRows: maxResultRows,
      maxResultBytes: maxResultBytes,
    );
    try {
      if (!await candidate.connect(loginTimeoutSeconds: timeoutInSeconds)) {
        return false;
      }
      if (dbName != null) await candidate.execute('USE $dbName');
      _client = candidate;
      return true;
    } catch (_) {
      await candidate.close();
      rethrow;
    }
  }, lifecycle: true);

  Future<SqlResponse> getData(String query) =>
      _schedule(() => _connected.execute(query));
  Future<SqlResponse> writeData(String query) => getData(query);
  Future<SqlResponse> getDataWithParams(
    String query,
    Map<String, dynamic> params,
  ) => _schedule(() => _connected.executeParams(query, params));
  Future<SqlResponse> writeDataWithParams(
    String query,
    Map<String, dynamic> params,
  ) => getDataWithParams(query, params);
  Future<SqlResponse> executeProcedure(
    String name,
    Map<String, dynamic> params,
  ) => _schedule(() => _connected.executeProcedure(name, params));
  Future<int> bulkInsert(
    String name,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) => _schedule(
    () => _connected.bulkInsert(
      name,
      rows,
      columns: columns,
      batchSize: batchSize,
    ),
  );

  Future<bool> disconnect() => _schedule(() async {
    final client = _client;
    _client = null;
    await client?.close();
    return true;
  }, lifecycle: true);

  /// Reserves the session for the entire callback, including its awaits.
  /// Calls outside its Zone wait; callbacks used after completion are rejected.
  /// Errors close/roll back the session; statements are never retried implicitly.
  Future<T> transaction<T>(Future<T> Function(MssqlConnection tx) action) {
    if (Zone.current[_transactionKey] != null) {
      return Future.error(StateError('Nested transactions are not supported'));
    }
    return _schedule(() async {
      final client = _connected;
      final token = Object();
      await client.execute('BEGIN TRAN');
      _activeTransaction = token;
      try {
        final result = await runZoned(
          () => action(this),
          zoneValues: {_transactionKey: token},
        );
        _activeTransaction = null;
        await client.execute('COMMIT');
        return result;
      } catch (_) {
        _activeTransaction = null;
        if (client.isConnected) {
          try {
            await client.execute('ROLLBACK');
          } catch (_) {
            await client.close();
          }
        }
        rethrow;
      }
    });
  }

  @Deprecated(
    'Use transaction((tx) async { ... }); manual shared transactions have no owner',
  )
  Future<void> beginTransaction() =>
      Future.error(UnsupportedError('Use transaction((tx) async { ... })'));
  @Deprecated('transaction commits automatically on success')
  Future<void> commit() =>
      Future.error(UnsupportedError('Use transaction((tx) async { ... })'));
  @Deprecated('transaction rolls back automatically on error')
  Future<void> rollback() =>
      Future.error(UnsupportedError('Use transaction((tx) async { ... })'));
}
