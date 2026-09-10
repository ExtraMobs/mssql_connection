import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'ffi/freetds_bindings.dart';
import 'ffi/freetds_text.dart';
import 'sql_exception.dart';
import 'sql_response.dart';

/// One serialized DB-Lib session. Native calls block the owning isolate.
class MssqlClient {
  final String server, username, password, caFile;
  final String? certificateHostname;
  final int queryTimeoutSeconds, maxResultRows, maxResultBytes;
  DBLib? _db;
  Pointer<DBPROCESS>? _dbproc;
  Future<void> _tail = Future.value();

  MssqlClient({
    required this.server,
    required this.username,
    required this.password,
    this.caFile = 'system',
    this.certificateHostname,
    this.queryTimeoutSeconds = 30,
    this.maxResultRows = 100000,
    this.maxResultBytes = 64 * 1024 * 1024,
    DBLib? dbLib,
  }) : _db = dbLib;

  bool get isConnected => _dbproc != null;
  Future<T> _run<T>(FutureOr<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  T _checked<T>(String operation, T Function() action, bool Function(T) ok) {
    final (value, diagnostics) = DBLib.captureDiagnostics(action);
    if (!ok(value)) {
      throw SQLException(
        '$operation failed${diagnostics.isEmpty ? '.' : ': ${diagnostics.join(' | ')}'}',
      );
    }
    return value;
  }

  void _check(String operation, int Function() action) =>
      _checked<int>(operation, action, (rc) => rc == SUCCEED);

  Future<bool> connect({int loginTimeoutSeconds = 15}) => _run(() async {
    if (isConnected) return true;
    if (loginTimeoutSeconds <= 0 ||
        loginTimeoutSeconds > 0x7fffffff ||
        queryTimeoutSeconds <= 0 ||
        queryTimeoutSeconds > 0x7fffffff ||
        maxResultRows <= 0 ||
        maxResultBytes <= 0) {
      throw ArgumentError(
        'Timeouts must fit a positive signed 32-bit integer; result limits must be positive',
      );
    }
    for (final text in [
      server,
      username,
      password,
      caFile,
      certificateHostname ?? '',
    ]) {
      if (text.contains('\u0000')) {
        throw ArgumentError('Login fields cannot contain NUL');
      }
    }
    if (server.isEmpty ||
        username.isEmpty ||
        password.isEmpty ||
        caFile.isEmpty) {
      throw ArgumentError('Server, credentials and CA trust must be specified');
    }
    if (caFile != 'system' && !File(caFile).isAbsolute) {
      throw ArgumentError('caFile must be an absolute PEM path or system');
    }
    final hp = _splitHostPort(server);
    if (hp != null) {
      try {
        final socket = await Socket.connect(
          hp.$1,
          hp.$2,
          timeout: Duration(seconds: loginTimeoutSeconds),
        );
        socket.destroy();
      } on SocketException {
        return false;
      }
    }
    final db = _db ??= DBLib.load();
    _check(
      'DB-Lib initialization (one owning isolate required)',
      () => db.initialize(kErrHandlerPtr, kMsgHandlerPtr),
    );
    _check('dbsetlogintime', () => db.dbsetlogintime(loginTimeoutSeconds));
    final login = _checked('dblogin', db.dblogin, (p) => p != nullptr);
    try {
      using((arena) {
        Pointer<Utf8> text(String value) =>
            toNativeFreeTdsText(value, allocator: arena);
        _check(
          'dbsetlcharset',
          () => db.dbsetlcharset(login, text(freeTdsClientCharset)),
        );
        _check('dbsetluser', () => db.dbsetluser(login, text(username)));
        _check('dbsetlpwd', () => db.dbsetlpwd(login, text(password)));
        // Feature gate: old binaries cannot silently bypass TLS/empty-value fixes.
        _check(
          'DBSETCAFILE (requires bundled FreeTDS)',
          () => db.dbsetlname(login, text(caFile), DBSETCAFILE),
        );
        _check(
          'DBSETCERTIFICATEHOSTNAME',
          () => db.dbsetlname(
            login,
            text(certificateHostname ?? hp?.$1 ?? server),
            DBSETCERTIFICATEHOSTNAME,
          ),
        );
        _check(
          'DBSETENCRYPTION',
          () => db.dbsetlname(login, text('require'), DBSETENCRYPTION),
        );
        _check('DBSETBCP', () => db.dbsetlbool(login, 1, DBSETBCP));
        _dbproc = _checked(
          'dbopen',
          () => db.dbopen(login, text(server)),
          (p) => p != nullptr,
        );
        _check(
          'DBSETTIME',
          () =>
              db.dbsetopt(_dbproc!, DBSETTIME, text('$queryTimeoutSeconds'), 0),
        );
      });
      _execute(
        'SET TEXTSIZE 2147483647; SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; '
        'SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; '
        'SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF;',
      );
      return true;
    } catch (_) {
      _close();
      rethrow;
    } finally {
      db.dbloginfree(login);
    }
  });

  Future<void> close() => _run(_close);
  void _close() {
    final proc = _dbproc;
    _dbproc = null;
    if (proc != null) {
      try {
        _db!.dbclose(proc);
      } finally {
        DBLib.takeLastMessage(proc);
        DBLib.takeLastError(proc);
      }
    }
  }

  T _operation<T>(T Function(DBLib, Pointer<DBPROCESS>) action) {
    final proc = _dbproc;
    if (proc == null) {
      throw SQLException('Not connected. Call connect() first.');
    }
    DBLib.takeLastError(proc);
    DBLib.takeLastMessage(proc);
    try {
      return action(_db!, proc);
    } catch (_) {
      // Closing aborts native buffers/BCP and rolls back any transaction.
      _close();
      rethrow;
    }
  }

  Future<SqlResponse> execute(String sql) => _run(() => _execute(sql));
  SqlResponse _execute(String sql) {
    if (sql.contains('\u0000')) throw ArgumentError('SQL cannot contain NUL');
    return _operation(
      (db, proc) => using((arena) {
        _check(
          'dbcmd',
          () => db.dbcmd(proc, toNativeFreeTdsText(sql, allocator: arena)),
        );
        _check('dbsqlexec', () => db.dbsqlexec(proc));
        return _collectResults(db, proc);
      }),
    );
  }

  Future<SqlResponse> executeParams(String sql, Map<String, dynamic> params) =>
      _run(() => _executeParams(sql, params));
  SqlResponse _executeParams(String sql, Map<String, dynamic> params) {
    final norm = _normalizeParams(params, limit: 2098);
    // Positional user arguments cannot collide with the built-in @stmt/@params.
    return _rpc('sp_executesql', [
      ('@stmt', sql),
      (
        '@params',
        norm.entries
            .map((e) => '${e.key} ${_inferSqlType(e.value)}')
            .join(', '),
      ),
      for (final value in norm.values) ('', value),
    ]);
  }

  Future<SqlResponse> executeProcedure(
    String name,
    Map<String, dynamic> params,
  ) => _run(
    () => _rpc(
      quoteSqlName(name),
      _normalizeParams(params).entries.map((e) => (e.key, e.value)).toList(),
    ),
  );
  SqlResponse _rpc(String name, List<(String, dynamic)> params) => using((
    arena,
  ) {
    final rpcName = toNativeFreeTdsText(name, allocator: arena);
    // Validate and encode before starting RPC; retain all buffers through send.
    final values = [
      for (final (key, value) in params)
        (
          toNativeFreeTdsText(key, allocator: arena),
          _encodeForRpc(value, arena),
        ),
    ];
    return _operation((db, proc) {
      _check('dbrpcinit', () => db.dbrpcinit(proc, rpcName, 0));
      for (final (key, value) in values) {
        _check(
          'dbrpcparam',
          () => db.dbrpcparam(
            proc,
            key,
            value.ptr != nullptr && value.length == 0 ? DBRPCEMPTY : 0,
            value.type,
            -1,
            value.length,
            value.ptr,
          ),
        );
      }
      _check('dbrpcsend', () => db.dbrpcsend(proc));
      _check('dbsqlok', () => db.dbsqlok(proc));
      return _collectResults(db, proc);
    });
  });

  /// Without a caller transaction, completed INSERTs/BCP batches remain committed
  /// if a later row fails. Use MssqlConnection.transaction for atomic bulk loads.
  Future<int> bulkInsert(
    String tableName,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) => _run(() {
    final table = quoteSqlName(tableName);
    if (batchSize <= 0) throw ArgumentError.value(batchSize, 'batchSize');
    if (rows.isEmpty) return 0;
    final cols = columns ?? rows.first.keys.toList();
    if (cols.isEmpty || cols.toSet().length != cols.length) {
      throw ArgumentError('Columns must be nonempty and unique');
    }
    final columnSql = cols.map(quoteSqlIdentifier).join(', ');
    for (final row in rows) {
      if (cols.any((c) => !row.containsKey(c))) {
        throw ArgumentError('Missing bulk column');
      }
    }
    final types = [for (final col in cols) _bulkType(rows.map((r) => r[col]))];
    var useBcp = !table.startsWith('[#') && !types.contains(null);
    if (useBcp) {
      final actual = _execute(
        'SELECT TOP (0) * FROM $table',
      ).resultSets.single.columns;
      useBcp =
          actual.length == cols.length &&
          List.generate(
            cols.length,
            (i) => actual[i] == cols[i],
          ).every((v) => v);
    }
    if (!useBcp) {
      // ponytail: one INSERT per row; optimize only with a charset-aware bulk path.
      final sql =
          'INSERT INTO $table ($columnSql) VALUES (${List.generate(cols.length, (i) => '@p$i').join(', ')})';
      for (final row in rows) {
        _executeParams(sql, {
          for (var i = 0; i < cols.length; i++) 'p$i': row[cols[i]],
        });
      }
      return rows.length;
    }
    return _operation(
      (db, proc) => using((arena) {
        _check(
          'bcp_init',
          () => db.bcp_init(
            proc,
            toNativeFreeTdsText(table, allocator: arena),
            nullptr,
            nullptr,
            DB_IN,
          ),
        );
        for (var i = 0; i < cols.length; i++) {
          _check(
            'bcp_bind',
            () =>
                db.bcp_bind(proc, nullptr, 0, -1, nullptr, 0, types[i]!, i + 1),
          );
        }
        var sent = 0, copied = 0;
        for (final row in rows) {
          using((rowArena) {
            for (var i = 0; i < cols.length; i++) {
              final v = _encodeForRpc(row[cols[i]], rowArena, type: types[i]);
              _check('bcp_collen', () => db.bcp_collen(proc, v.length, i + 1));
              _check('bcp_colptr', () => db.bcp_colptr(proc, v.ptr, i + 1));
            }
            _check('bcp_sendrow', () => db.bcp_sendrow(proc));
          });
          if (++sent % batchSize == 0) {
            copied += _checked(
              'bcp_batch',
              () => db.bcp_batch(proc),
              (n) => n >= 0,
            );
          }
        }
        copied += _checked('bcp_done', () => db.bcp_done(proc), (n) => n >= 0);
        return copied;
      }),
    );
  });

  SqlResponse _collectResults(DBLib db, Pointer<DBPROCESS> proc) {
    final sets = <SqlResultSet>[];
    var affected = 0, rowCount = 0, bytes = 0;
    while (true) {
      final result = _checked(
        'dbresults',
        () => db.dbresults(proc),
        (rc) => rc == SUCCEED || rc == NO_MORE_RESULTS,
      );
      if (result == NO_MORE_RESULTS) break;
      final count = db.dbnumcols(proc);
      if (count < 0) throw SQLException('Invalid column count');
      final types = [for (var i = 1; i <= count; i++) db.dbcoltype(proc, i)];
      final columns = [
        for (var i = 1; i <= count; i++)
          fromNativeFreeTdsText(db.dbcolname(proc, i)),
      ];
      final rows = <List<dynamic>>[];
      if (count > 0) {
        while (true) {
          final next = _checked(
            'dbnextrow',
            () => db.dbnextrow(proc),
            (rc) => rc == REG_ROW || rc == NO_MORE_ROWS,
          );
          if (next == NO_MORE_ROWS) break;
          if (++rowCount > maxResultRows) {
            throw SQLException('Result row limit exceeded');
          }
          final row = <dynamic>[];
          for (var i = 1; i <= count; i++) {
            final len = db.dbdatlen(proc, i);
            if (len < 0) throw SQLException('Invalid column length');
            bytes += len;
            if (bytes > maxResultBytes) {
              throw SQLException('Result byte limit exceeded');
            }
            row.add(
              decodeDbValueWithFallback(
                db,
                proc,
                types[i - 1],
                db.dbdata(proc, i),
                len,
              ),
            );
          }
          rows.add(row);
        }
        sets.add(SqlResultSet(columns: columns, rows: rows));
      }
      final countAffected = db.dbcount(proc);
      if (countAffected > 0) affected += countAffected;
    }
    return SqlResponse(resultSets: sets, totalAffectedRows: affected);
  }
}

(String, int)? _splitHostPort(String server) {
  final colon = server.lastIndexOf(':');
  if (colon <= 0) return null;
  final port = int.tryParse(server.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  var host = server.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return (host, port);
}

String quoteSqlIdentifier(String value) {
  if (value.isEmpty || value.length > 128 || value.contains('\u0000')) {
    throw ArgumentError('Invalid SQL identifier');
  }
  return '[${value.replaceAll(']', ']]')}]';
}

/// Parse regular or bracket-quoted multipart identifiers, never SQL expressions.
String quoteSqlName(String value) {
  final parts = <String>[];
  var i = 0;
  while (i < value.length) {
    while (i < value.length && value[i].trim().isEmpty) {
      i++;
    }
    final part = StringBuffer();
    if (i < value.length && value[i] == '[') {
      i++;
      var closed = false;
      while (i < value.length) {
        final ch = value[i++];
        if (ch == ']') {
          if (i < value.length && value[i] == ']') {
            part.write(']');
            i++;
          } else {
            closed = true;
            break;
          }
        } else {
          part.write(ch);
        }
      }
      if (!closed) throw ArgumentError('Unclosed SQL identifier');
    } else {
      final start = i;
      while (i < value.length && value[i] != '.') {
        i++;
      }
      final raw = value.substring(start, i).trim();
      if (!RegExp(
        r'^[\p{L}_#][\p{L}\p{N}_@$#]*$',
        unicode: true,
      ).hasMatch(raw)) {
        throw ArgumentError('Invalid SQL identifier');
      }
      part.write(raw);
    }
    parts.add(quoteSqlIdentifier(part.toString()));
    while (i < value.length && value[i].trim().isEmpty) {
      i++;
    }
    if (i == value.length) break;
    if (value[i++] != '.' || i == value.length) {
      throw ArgumentError('Invalid SQL name');
    }
  }
  if (parts.isEmpty || parts.length > 4) {
    throw ArgumentError('Invalid SQL name');
  }
  return parts.join('.');
}

Map<String, dynamic> _normalizeParams(
  Map<String, dynamic> params, {
  int limit = 2100,
}) {
  final result = <String, dynamic>{};
  final seen = <String>{};
  for (final entry in params.entries) {
    final name = entry.key.startsWith('@') ? entry.key : '@${entry.key}';
    if (name.length > 128 ||
        !RegExp(r'^@[\p{L}_][\p{L}\p{N}_]*$', unicode: true).hasMatch(name)) {
      throw ArgumentError('Invalid SQL parameter name');
    }
    if (!seen.add(name.toLowerCase())) {
      throw ArgumentError('Duplicate SQL parameter');
    }
    result[name] = entry.value;
  }
  if (result.length > limit) {
    throw ArgumentError('SQL Server parameter limit exceeded');
  }
  return result;
}

String _inferSqlType(dynamic v) {
  if (v is bool) return 'bit';
  if (v is int) return v < -2147483648 || v > 2147483647 ? 'bigint' : 'int';
  if (v is double) return 'float';
  if (v is DateTime) return 'datetimeoffset(7)';
  if (v is Uint8List) return 'varbinary(max)';
  return 'nvarchar(max)';
}

int? _bulkType(Iterable<dynamic> values) {
  if (values.every((v) => v is int)) {
    return values.any((v) => v < -2147483648 || v > 2147483647)
        ? SYBINT8
        : SYBINT4;
  }
  if (values.every((v) => v is double && v.isFinite)) return SYBFLT8;
  if (values.every((v) => v is bool)) return SYBBIT;
  if (values.every((v) => v is Uint8List && v.isNotEmpty)) return SYBVARBINARY;
  return null;
}

class _RpcValue {
  final int type, length;
  final Pointer<Uint8> ptr;
  _RpcValue(this.type, this.ptr, this.length);
}

_RpcValue _encodeForRpc(dynamic value, Allocator arena, {int? type}) {
  if (value == null) return _RpcValue(SYBNTEXT, nullptr, 0);
  if (value is int) {
    if (type == SYBINT8 || value < -2147483648 || value > 2147483647) {
      final p = arena<Int64>()..value = value;
      return _RpcValue(SYBINT8, p.cast(), 8);
    }
    final p = arena<Int32>()..value = value;
    return _RpcValue(SYBINT4, p.cast(), 4);
  }
  if (value is double) {
    if (!value.isFinite) throw ArgumentError('SQL float must be finite');
    final p = arena<Double>()..value = value;
    return _RpcValue(SYBFLT8, p.cast(), 8);
  }
  if (value is bool) {
    final p = arena<Uint8>()..value = value ? 1 : 0;
    return _RpcValue(SYBBIT, p, 1);
  }
  if (value is DateTime) {
    final utc = value.toUtc();
    if (utc.year < 1 ||
        utc.year > 9999 ||
        value.timeZoneOffset.inMinutes.abs() > 840) {
      throw ArgumentError('DateTime outside SQL Server datetimeoffset range');
    }
    final p = arena<Uint8>(16);
    p.asTypedList(16).fillRange(0, 16, 0);
    final bytes = ByteData.sublistView(p.asTypedList(16));
    final midnight = DateTime.utc(utc.year, utc.month, utc.day);
    bytes.setUint64(
      0,
      utc.difference(midnight).inMicroseconds * 10,
      Endian.host,
    );
    bytes.setInt32(
      8,
      midnight.difference(DateTime.utc(1900, 1, 1)).inDays,
      Endian.host,
    );
    bytes.setInt16(12, value.timeZoneOffset.inMinutes, Endian.host);
    bytes.setUint16(14, 7 | (1 << 13) | (1 << 14) | (1 << 15), Endian.host);
    return _RpcValue(SYBMSDATETIMEOFFSET, p, 16);
  }
  final bytes = value is Uint8List
      ? value
      : freeTdsTextCodec.encode(value.toString());
  final p = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedList(bytes.length).setAll(0, bytes);
  return _RpcValue(
    value is Uint8List ? SYBVARBINARY : SYBNTEXT,
    p,
    bytes.length,
  );
}
