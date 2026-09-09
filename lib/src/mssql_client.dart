import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi/freetds_bindings.dart';
import 'ffi/freetds_text.dart';
import 'native_logger.dart';
import 'sql_exception.dart';
import 'sql_response.dart';

class MssqlClient {
  final String server;
  final String username;
  final String password;

  DBLib? _db;
  Pointer<DBPROCESS>? _dbproc;
  bool _connected = false;

  MssqlClient({
    required this.server,
    required this.username,
    required this.password,
    DBLib? dbLib,
  }) : _db = dbLib;

  bool get isConnected => _connected;

  T _loginCall<T>(String operation, T Function() action, bool Function(T) ok) {
    final (value, diagnostics) = DBLib.captureDiagnostics(action);
    if (!ok(value)) {
      throw SQLException(
        '$operation failed${diagnostics.isEmpty ? '.' : ': ${diagnostics.join(' | ')}'}',
      );
    }
    return value;
  }

  /// Establish a DB-Lib connection to [server] using [username]/[password].
  ///
  /// Steps:
  /// 1) Load and initialize DB-Lib (dbinit)
  /// 1.1) Set login timeout via dbsetlogintime([loginTimeoutSeconds])
  /// 2) Allocate a LOGINREC (dblogin)
  /// 3) Set credentials (dbsetluser/dbsetlpwd)
  /// 4) Enable BCP option on the login (best-effort)
  /// 5) Open a DBPROCESS to the server (dbopen)
  ///
  /// Returns true on success; false if the TCP probe fails. Native login
  /// failures throw SQLException with callback diagnostics. All native buffers
  /// for username/password/server are freed after use.
  ///
  /// [loginTimeoutSeconds] controls how long DB-Lib waits to establish a socket
  /// connection/login before failing. Default is 15 seconds.
  ///
  /// Logging: emits lines in the form `connect | key=value | ...` for traceability.
  Future<bool> connect({int loginTimeoutSeconds = 15}) async {
    if (_connected) {
      MssqlLogger.i('connect | already-connected=true');
      return true;
    }
    try {
      MssqlLogger.i('connect | op=init | status=start');
      // Preflight: if server string looks like host:port, try a quick TCP probe
      final hp = _splitHostPort(server);
      if (hp != null) {
        final ok = await _probeTcp(
          hp.$1,
          hp.$2,
          Duration(seconds: loginTimeoutSeconds),
        );
        if (!ok) {
          MssqlLogger.w(
            'connect | op=probe | host=${hp.$1} | port=${hp.$2} | reachable=false',
          );
          return false;
        }
        MssqlLogger.i(
          'connect | op=probe | host=${hp.$1} | port=${hp.$2} | reachable=true',
        );
      }
      _db ??= DBLib.load();
      // Install handlers early so DB-Lib won't use its default fatal handler on errors in dbopen.
      try {
        _db!.dberrhandle(kErrHandlerPtr);
        _db!.dbmsghandle(kMsgHandlerPtr);
        MssqlLogger.i('connect | op=handlers | status=installed');
      } catch (e) {
        MssqlLogger.w('connect | op=handlers | error=$e');
        rethrow;
      }
      _loginCall('dbinit', () => _db!.dbinit(), (rc) => rc == SUCCEED);

      // Configure login timeout (best set before attempting to connect)
      try {
        final rc = _db!.dbsetlogintime(loginTimeoutSeconds);
        MssqlLogger.i(
          'connect | op=dbsetlogintime | seconds=$loginTimeoutSeconds | rc=$rc',
        );
      } catch (e) {
        MssqlLogger.w('connect | op=dbsetlogintime | error=$e');
      }

      MssqlLogger.i('connect | op=dblogin');
      final login = _loginCall(
        'dblogin',
        () => _db!.dblogin(),
        (p) => p != nullptr,
      );

      using((arena) {
        final charset = toNativeFreeTdsText(
          freeTdsClientCharset,
          allocator: arena,
        );
        _loginCall(
          'dbsetlcharset',
          () => _db!.dbsetlcharset(login, charset),
          (rc) => rc == SUCCEED,
        );
        final u = toNativeFreeTdsText(username, allocator: arena);
        final p = toNativeFreeTdsText(password, allocator: arena);
        MssqlLogger.i('connect | op=dbsetluser');
        final su = _loginCall(
          'dbsetluser',
          () => _db!.dbsetluser(login, u),
          (rc) => rc == SUCCEED,
        );
        MssqlLogger.i('connect | op=dbsetluser | rc=$su');

        MssqlLogger.i('connect | op=dbsetlpwd');
        final sp = _loginCall(
          'dbsetlpwd',
          () => _db!.dbsetlpwd(login, p),
          (rc) => rc == SUCCEED,
        );
        MssqlLogger.i('connect | op=dbsetlpwd | rc=$sp');

        // Enable BCP on this login so that bulk insert APIs are available on the session.
        try {
          final rcBcp = _db!.dbsetlbool(login, 1, DBSETBCP);
          MssqlLogger.i(
            'connect | op=dbsetlbool | option=DBSETBCP | value=1 | rc=$rcBcp',
          );
        } catch (e) {
          MssqlLogger.w(
            'connect | op=dbsetlbool | option=DBSETBCP | value=1 | error=$e',
          );
        }
      });

      final srv = toNativeFreeTdsText(server);
      try {
        MssqlLogger.i('connect | op=dbopen | server=$server');
        _dbproc = _loginCall(
          'dbopen',
          () => _db!.dbopen(login, srv),
          (p) => p != nullptr,
        );
      } finally {
        malloc.free(srv);
      }

      // Increase TEXT/NTEXT retrieval limit to avoid 4096-byte default truncation.
      // Use T-SQL SET TEXTSIZE to ensure compatibility across DB-Lib variants.
      try {
        const String cmdText = 'SET TEXTSIZE 2147483647';
        final setPtr = toNativeFreeTdsText(cmdText);
        try {
          final rc1 = _db!.dbcmd(_dbproc!, setPtr);
          MssqlLogger.i('connect | op=dbcmd | sql=SET TEXTSIZE | rc=$rc1');
          if (rc1 == SUCCEED) {
            final rc2 = _db!.dbsqlexec(_dbproc!);
            MssqlLogger.i('connect | op=dbsqlexec | rc=$rc2');
            if (rc2 == SUCCEED) {
              // Drain the SET batch quietly
              _collectResults(_db!, _dbproc!);
            }
          }
        } finally {
          malloc.free(setPtr);
        }
      } catch (e) {
        MssqlLogger.w('connect | op=set-textsize | error=$e');
      }

      _connected = true;
      MssqlLogger.i('connect | status=connected | server=$server');
      return true;
    } catch (e, st) {
      MssqlLogger.e('connect | exception=$e');
      MssqlLogger.w('connect | stacktrace=\n$st');
      rethrow;
    }
  }

  // Parse a host:port string into (host, port). Returns null if not in that form.
  (String, int)? _splitHostPort(String s) {
    final idx = s.lastIndexOf(':');
    if (idx <= 0 || idx == s.length - 1) return null;
    final host = s.substring(0, idx);
    final pStr = s.substring(idx + 1);
    final port = int.tryParse(pStr);
    if (port == null) return null;
    return (host, port);
  }

  // Attempt a TCP connection to host:port within [timeout].
  Future<bool> _probeTcp(String host, int port, Duration timeout) async {
    try {
      final sock = await Socket.connect(host, port, timeout: timeout);
      // Immediately dispose; this is a reachability probe only.
      await sock.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Close the active DBPROCESS if connected and mark the client disconnected.
  ///
  /// Behavior:
  /// - If no active connection exists, returns immediately (idempotent).
  /// - Calls dbclose(DBPROCESS*) and logs the return code.
  /// - Clears the internal DBPROCESS pointer and connected flag.
  ///
  /// Note: This does not call dbexit(); the library remains loaded for reuse.
  /// Logging: emits lines in the form `close | key=value | ...` for traceability.
  Future<void> close() async {
    MssqlLogger.i('close | requested=true');
    if (_dbproc == null || _dbproc == nullptr) {
      _connected = false;
      MssqlLogger.i('close | no-active=true | status=disconnected');
      return;
    }
    try {
      MssqlLogger.i('close | op=dbclose');
      final rc = _db!.dbclose(_dbproc!);
      MssqlLogger.i('close | op=dbclose | rc=$rc');
    } catch (e) {
      MssqlLogger.w('close | op=dbclose | error=$e');
    } finally {
      _dbproc = null;
      _connected = false;
      MssqlLogger.i('close | status=disconnected');
    }
  }

  /// Bulk insert rows into [tableName].
  ///
  /// [rows] should be a non-empty list of homogeneous maps.
  /// If [columns] is not provided, the keys of the first row (iteration order)
  /// are used as the column order.
  /// Returns the number of rows successfully copied.
  Future<int> bulkInsert(
    String tableName,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) async {
    _ensureConnected();
    if (rows.isEmpty) return 0;
    final db = _db!;
    final dbproc = _dbproc!;

    final cols = (columns != null && columns.isNotEmpty)
        ? List<String>.from(columns)
        : rows.first.keys.toList(growable: false);

    // FreeTDS 1.5.4 BCP from program variables bypasses charset conversion.
    // Route text (including DateTime/custom values and NULL inference) through RPC.
    // ponytail: one INSERT per row for text; optimize only with a charset-aware bulk path.
    final tn = tableName.trim();
    if (tn.startsWith('#') ||
        rows.any((row) => cols.any((c) => _hostTypeFor(row[c]) == SYBNTEXT))) {
      final colList = cols
          .map((c) => '[${c.replaceAll(']', ']]')}]')
          .join(', ');
      final placeholders = List.generate(cols.length, (i) => '@p$i').join(', ');
      final sql = 'INSERT INTO $tableName ($colList) VALUES ($placeholders)';
      int total = 0;
      for (final row in rows) {
        final res = await executeParams(sql, {
          for (var i = 0; i < cols.length; i++) 'p$i': row[cols[i]],
        });
        if (res.error != null) {
          throw SQLException(res.error!);
        }
        if (res.totalAffectedRows > 0) total++;
      }
      return total;
    }

    // Initialize BCP
    final tbl = toNativeFreeTdsText(tableName);
    try {
      final rcInit = db.bcp_init(dbproc, tbl, nullptr, nullptr, DB_IN);
      if (rcInit != SUCCEED) {
        throw SQLException('bcp_init failed for $tableName');
      }

      // Bind columns with host types; varaddr NULL, varlen -1, no terminator
      final hostTypes = <int>[];
      for (var i = 0; i < cols.length; i++) {
        final sample = rows.first[cols[i]];
        final htype = _hostTypeFor(sample);
        hostTypes.add(htype);
        final rcBind = db.bcp_bind(
          dbproc,
          nullptr,
          0,
          -1,
          nullptr,
          0,
          htype,
          i + 1,
        );
        if (rcBind != SUCCEED) {
          throw SQLException('bcp_bind failed for column ${i + 1}');
        }
      }

      int sent = 0;
      int total = 0;

      // Row buffers per column allocated per row (freed after send)
      for (final row in rows) {
        final allocs = <_TempBuf>[];
        try {
          // Set data pointers/lengths for this row
          for (var i = 0; i < cols.length; i++) {
            final v = row[cols[i]];
            if (v == null) {
              // Indicate NULL
              db.bcp_collen(dbproc, -1, i + 1);
              db.bcp_colptr(dbproc, nullptr, i + 1);
              continue;
            }
            final buf = _encodeForHost(hostTypes[i], v);
            allocs.add(buf);
            db.bcp_collen(dbproc, buf.length, i + 1);
            db.bcp_colptr(dbproc, buf.ptr.cast<Uint8>(), i + 1);
          }

          // Send the row
          final rcSend = db.bcp_sendrow(dbproc);
          if (rcSend != SUCCEED) {
            throw SQLException('bcp_sendrow failed');
          }
          sent++;

          // Batch if needed
          if (batchSize > 0 && (sent % batchSize == 0)) {
            final b = db.bcp_batch(dbproc);
            if (b < 0) {
              throw SQLException('bcp_batch failed');
            }
            total += b;
          }
        } finally {
          // Free allocated buffers for this row
          for (final a in allocs) {
            malloc.free(a.ptr);
          }
        }
      }

      // Finalize
      final done = db.bcp_done(dbproc);
      if (done < 0) {
        throw SQLException('bcp_done failed');
      }
      total += done;
      return total;
    } finally {
      malloc.free(tbl);
    }
  }

  /// Execute a plain SQL text command and return its result sets and row counts.
  ///
  /// Logging: emits lines in the form `execute | key=value | ...`.
  Future<SqlResponse> execute(String sql) async {
    _ensureConnected();
    final db = _db!;
    final dbproc = _dbproc!;

    // Clear any stale messages from previous queries
    DBLib.takeLastMessage(dbproc);
    DBLib.takeLastError(dbproc);

    // Detect if we should enable strict SET options for this statement
    final _SetPlan plan = _analyzeSetNeeds(sql);
    if (plan.needsSet) {
      // 1) Enable options in their own batch
      final setCmd = toNativeFreeTdsText(plan.setPrefix);
      try {
        MssqlLogger.i('execute | op=dbcmd | sqlLen=${plan.setPrefix.length}');
        final rc1 = db.dbcmd(dbproc, setCmd);
        if (rc1 != SUCCEED) {
          MssqlLogger.e('execute | op=dbcmd | rc=$rc1 | error=fail');
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbcmd failed (SET options)');
        }
        MssqlLogger.i('execute | op=dbsqlexec');
        final rc2 = db.dbsqlexec(dbproc);
        if (rc2 != SUCCEED) {
          MssqlLogger.e('execute | op=dbsqlexec | rc=$rc2 | error=fail');
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbsqlexec failed (SET options)');
        }
        // Drain results for SET batch
        _collectResults(db, dbproc);
      } finally {
        malloc.free(setCmd);
      }

      // 2) Execute the original SQL in its own batch (ensuring CREATE VIEW is first)
      final cmd = toNativeFreeTdsText(sql);
      try {
        MssqlLogger.i('execute | op=dbcmd | sqlLen=${sql.length}');
        final rc1 = db.dbcmd(dbproc, cmd);
        if (rc1 != SUCCEED) {
          MssqlLogger.e('execute | op=dbcmd | rc=$rc1 | error=fail');
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbcmd failed');
        }
        MssqlLogger.i('execute | op=dbsqlexec');
        final rc2 = db.dbsqlexec(dbproc);
        if (rc2 != SUCCEED) {
          MssqlLogger.e('execute | op=dbsqlexec | rc=$rc2 | error=fail');
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbsqlexec failed');
        }
        return _collectResults(db, dbproc);
      } finally {
        malloc.free(cmd);
      }
    } else {
      // Regular path
      final cmd = toNativeFreeTdsText(sql);
      try {
        MssqlLogger.i('execute | op=dbcmd | sqlLen=${sql.length}');
        final rc1 = db.dbcmd(dbproc, cmd);
        if (rc1 != SUCCEED) {
          MssqlLogger.e('execute | op=dbcmd | rc=$rc1 | error=fail');
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbcmd failed');
        }
        MssqlLogger.i('execute | op=dbsqlexec');
        final rc2 = db.dbsqlexec(dbproc);
        if (rc2 != SUCCEED) {
          MssqlLogger.e('execute | op=dbsqlexec | rc=$rc2 | error=fail');
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbsqlexec failed');
        }
        return _collectResults(db, dbproc);
      } finally {
        malloc.free(cmd);
      }
    }
  }

  /// Execute parameterized SQL via DB-Lib RPC to sp_executesql.
  ///
  /// - [sql]: text with @param placeholders (e.g., SELECT * FROM T WHERE c=@p)
  /// - [params]: map of parameterName -> value (name can include or omit leading @)
  ///
  /// This uses the DB-Lib RPC path:
  /// 1) dbrpcinit(dbproc, 'sp_executesql', 0)
  /// 2) dbrpcparam for @stmt (NVARCHAR) and @params (NVARCHAR)
  /// 3) dbrpcparam for each user parameter (typed, binary-safe)
  /// 4) dbrpcsend + dbsqlok, then results are collected via [_collectResults].
  ///
  /// Benefits: avoids string concatenation and quoting, preserves types, and
  /// leverages the server to plan/execute with true parameters.
  ///
  /// Logging: emits lines in the form `executeParams | key=value | ...`.
  Future<SqlResponse> executeParams(
    String sql,
    Map<String, dynamic> params,
  ) async {
    _ensureConnected();
    final db = _db!;
    final dbproc = _dbproc!;

    // Clear any stale messages from previous queries
    DBLib.takeLastMessage(dbproc);
    DBLib.takeLastError(dbproc);

    // Normalize param names to include '@'
    final norm = <String, dynamic>{};
    params.forEach((k, v) => norm[_normalizeParamName(k)] = v);
    MssqlLogger.i('executeParams | op=normalize | count=${norm.length}');

    // Build parameter declaration string (e.g., "@p1 int, @p2 nvarchar(max)")
    final decls = <String>[];
    for (final e in norm.entries) {
      final declType = _inferSqlType(e.value);
      decls.add('${e.key} $declType');
    }
    final declStr = decls.join(', ');

    // All RPC text is UTF-8 in client memory; FreeTDS converts it to Unicode.
    final rpcName = toNativeFreeTdsText('sp_executesql');
    final stmtBuf = _encodeForRpc(sql);
    final paramsBuf = _encodeForRpc(declStr);

    // We'll pass Utf8 pointers directly; no extra copies
    final tempAllocations = <_TempBuf>[]; // values for user params

    try {
      MssqlLogger.i('executeParams | op=dbrpcinit | rpc=sp_executesql');
      final rcInit = db.dbrpcinit(dbproc, rpcName, 0);
      if (rcInit != SUCCEED) {
        MssqlLogger.e('executeParams | op=dbrpcinit | rc=$rcInit | error=fail');
        // In case previous RPC left state dirty, attempt a reset
        try {
          final empty = toNativeFreeTdsText('');
          db.dbrpcinit(dbproc, empty, DBRPCRESET);
          malloc.free(empty);
        } catch (_) {}
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbrpcinit failed');
      }

      // Unicode SQL, with byte lengths measured before FreeTDS conversion.
      final nameStmt = toNativeFreeTdsText('@stmt');
      final rcP1 = db.dbrpcparam(
        dbproc,
        nameStmt,
        0,
        stmtBuf.type,
        -1, // maxlen: -1 for non-OUTPUT
        stmtBuf.buf.length, // datalen: raw byte count
        stmtBuf.buf.ptr,
      );
      malloc.free(nameStmt);
      if (rcP1 != SUCCEED) {
        MssqlLogger.e(
          'executeParams | op=dbrpcparam | name=@stmt | rc=$rcP1 | error=fail',
        );
        // Reset RPC state to allow future dbrpcinit calls
        try {
          final z = toNativeFreeTdsText('');
          db.dbrpcinit(dbproc, z, DBRPCRESET);
          malloc.free(z);
        } catch (_) {}
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbrpcparam @stmt failed');
      }

      final nameParams = toNativeFreeTdsText('@params');
      final rcP2 = db.dbrpcparam(
        dbproc,
        nameParams,
        0,
        paramsBuf.type,
        -1, // maxlen: -1 for non-OUTPUT
        paramsBuf.buf.length, // datalen: raw byte count
        paramsBuf.buf.ptr,
      );
      malloc.free(nameParams);
      if (rcP2 != SUCCEED) {
        MssqlLogger.e(
          'executeParams | op=dbrpcparam | name=@params | rc=$rcP2 | error=fail',
        );
        try {
          final z = toNativeFreeTdsText('');
          db.dbrpcinit(dbproc, z, DBRPCRESET);
          malloc.free(z);
        } catch (_) {}
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbrpcparam @params failed');
      }

      // User parameters: add in the same order as declarations
      for (final e in norm.entries) {
        final name = e.key; // includes @
        final value = e.value;
        final rpcVal = _encodeForRpc(value);
        tempAllocations.add(rpcVal.buf);
        final cname = toNativeFreeTdsText(name);
        final rcPi = db.dbrpcparam(
          dbproc,
          cname,
          0, // input param
          rpcVal.type,
          -1, // maxlen: -1 for non-OUTPUT
          rpcVal.buf.length, // datalen: raw byte count
          rpcVal.buf.ptr,
        );
        malloc.free(cname);
        if (rcPi != SUCCEED) {
          MssqlLogger.e(
            'executeParams | op=dbrpcparam | name=$name | rc=$rcPi | error=fail',
          );
          try {
            final z = toNativeFreeTdsText('');
            db.dbrpcinit(dbproc, z, DBRPCRESET);
            malloc.free(z);
          } catch (_) {}
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbrpcparam failed');
        }
      }

      MssqlLogger.i('executeParams | op=dbrpcsend');
      final rcSend = db.dbrpcsend(dbproc);
      if (rcSend != SUCCEED) {
        MssqlLogger.e('executeParams | op=dbrpcsend | rc=$rcSend | error=fail');
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbrpcsend failed');
      }

      MssqlLogger.i('executeParams | op=dbsqlok');
      final rcOk = db.dbsqlok(dbproc);
      if (rcOk != SUCCEED) {
        MssqlLogger.e('executeParams | op=dbsqlok | rc=$rcOk | error=fail');
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbsqlok failed');
      }

      // Read results via shared collector
      return _collectResults(db, dbproc);
    } finally {
      // Free buffers for @stmt/@params and user param values
      malloc.free(stmtBuf.buf.ptr);
      malloc.free(paramsBuf.buf.ptr);
      for (final t in tempAllocations) {
        malloc.free(t.ptr);
      }
      malloc.free(rpcName);
    }
  }

  /// Execute a stored procedure directly via DB-Lib RPC.
  ///
  /// - [procName]: The name of the stored procedure.
  /// - [params]: map of parameterName -> value.
  ///
  /// This uses direct RPC: dbrpcinit(dbproc, procName, 0) followed by dbrpcparam for each parameter.
  Future<SqlResponse> executeProcedure(
    String procName,
    Map<String, dynamic> params,
  ) async {
    _ensureConnected();
    final db = _db!;
    final dbproc = _dbproc!;

    // Clear any stale messages from previous queries
    DBLib.takeLastMessage(dbproc);
    DBLib.takeLastError(dbproc);

    final norm = <String, dynamic>{};
    params.forEach((k, v) => norm[_normalizeParamName(k)] = v);
    MssqlLogger.i('executeProcedure | op=normalize | count=${norm.length}');

    final rpcName = toNativeFreeTdsText(procName);
    final tempAllocations = <_TempBuf>[];

    try {
      MssqlLogger.i('executeProcedure | op=dbrpcinit | rpc=$procName');
      final rcInit = db.dbrpcinit(dbproc, rpcName, 0);
      if (rcInit != SUCCEED) {
        MssqlLogger.e(
          'executeProcedure | op=dbrpcinit | rc=$rcInit | error=fail',
        );
        try {
          final empty = toNativeFreeTdsText('');
          db.dbrpcinit(dbproc, empty, DBRPCRESET);
          malloc.free(empty);
        } catch (_) {}
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbrpcinit failed for $procName');
      }

      for (final e in norm.entries) {
        final name = e.key;
        final value = e.value;
        final rpcVal = _encodeForRpc(value);
        tempAllocations.add(rpcVal.buf);
        final cname = toNativeFreeTdsText(name);

        final rcPi = db.dbrpcparam(
          dbproc,
          cname,
          0, // input param
          rpcVal.type,
          -1, // maxlen
          rpcVal.buf.length, // datalen: raw byte count
          rpcVal.buf.ptr,
        );
        malloc.free(cname);
        if (rcPi != SUCCEED) {
          MssqlLogger.e(
            'executeProcedure | op=dbrpcparam | name=$name | rc=$rcPi | error=fail',
          );
          try {
            final z = toNativeFreeTdsText('');
            db.dbrpcinit(dbproc, z, DBRPCRESET);
            malloc.free(z);
          } catch (_) {}
          final em =
              DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
          throw SQLException(em ?? 'dbrpcparam failed for $name');
        }
      }

      MssqlLogger.i('executeProcedure | op=dbrpcsend');
      final rcSend = db.dbrpcsend(dbproc);
      if (rcSend != SUCCEED) {
        MssqlLogger.e(
          'executeProcedure | op=dbrpcsend | rc=$rcSend | error=fail',
        );
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbrpcsend failed');
      }

      MssqlLogger.i('executeProcedure | op=dbsqlok');
      final rcOk = db.dbsqlok(dbproc);
      if (rcOk != SUCCEED) {
        MssqlLogger.e('executeProcedure | op=dbsqlok | rc=$rcOk | error=fail');
        final em = DBLib.takeLastMessage(dbproc) ?? DBLib.takeLastError(dbproc);
        throw SQLException(em ?? 'dbsqlok failed');
      }

      return _collectResults(db, dbproc);
    } finally {
      for (final t in tempAllocations) {
        malloc.free(t.ptr);
      }
      malloc.free(rpcName);
    }
  }
  // --- Internals ---

  /// Collect rows and counts from the DB-Lib results pipeline.
  ///
  /// Behavior and design:
  /// - Iterates dbresults() until NO_MORE_RESULTS.
  /// - Captures every result set with columns and aggregates dbcount().
  /// - Decodes each value using decodeDbValueWithFallback() for safety.
  ///
  /// Logging: emits standardized lines prefixed with `collectResults`.
  ///
  /// Returns a SqlResponse, with any result-collection error recorded separately.
  SqlResponse _collectResults(DBLib db, Pointer<DBPROCESS> dbproc) {
    final resultSets = <SqlResultSet>[];
    int affectedTotal = 0;
    String? error;

    MssqlLogger.i('collectResults | op=start');
    int setIndex = 0;
    while (true) {
      final r = db.dbresults(dbproc);
      if (r == NO_MORE_RESULTS) {
        MssqlLogger.i('collectResults | op=dbresults | result=$r | status=end');
        break;
      }
      if (r != SUCCEED) {
        error = 'dbresults failed (rc=$r)';
        MssqlLogger.e('collectResults | op=dbresults | rc=$r | error=fail');
        break;
      }
      setIndex++;
      final ncols = db.dbnumcols(dbproc);
      MssqlLogger.i('collectResults | op=set | index=$setIndex | ncols=$ncols');
      final types = List<int>.filled(ncols, 0);
      final columns = <String>[];

      if (ncols > 0) {
        for (var i = 1; i <= ncols; i++) {
          final cptr = db.dbcolname(dbproc, i);
          types[i - 1] = db.dbcoltype(dbproc, i);
          final name = cptr == nullptr ? 'col$i' : fromNativeFreeTdsText(cptr);
          columns.add(name);
        }
        MssqlLogger.i('collectResults | op=columns | count=${columns.length}');
      }

      int fetched = 0;
      final rows = <List<dynamic>>[];
      if (ncols > 0 && columns.isNotEmpty) {
        while (true) {
          final nr = db.dbnextrow(dbproc);
          if (nr == NO_MORE_ROWS) break;
          if (nr != REG_ROW && nr != MORE_ROWS) {
            MssqlLogger.w(
              'collectResults | op=dbnextrow | rc=$nr | warning=unexpected',
            );
            break;
          }
          final row = <dynamic>[];
          for (var i = 1; i <= ncols; i++) {
            final t = types[i - 1];
            final len = db.dbdatlen(dbproc, i);
            final ptr = db.dbdata(dbproc, i);
            final v = decodeDbValueWithFallback(db, dbproc, t, ptr, len);
            row.add(v);
          }
          rows.add(row);
          fetched++;
        }
        MssqlLogger.i(
          'collectResults | op=rows | set=$setIndex | fetched=$fetched',
        );
        resultSets.add(SqlResultSet(columns: columns, rows: rows));
      }

      try {
        final c = db.dbcount(dbproc);
        affectedTotal += c;
        MssqlLogger.i(
          'collectResults | op=dbcount | set=$setIndex | value=$c | total=$affectedTotal',
        );
      } catch (e) {
        MssqlLogger.w('collectResults | op=dbcount | set=$setIndex | error=$e');
      }
    }

    MssqlLogger.i(
      'collectResults | status=done | sets=${resultSets.length} | affected=$affectedTotal',
    );
    return SqlResponse(
      resultSets: resultSets,
      totalAffectedRows: affectedTotal,
      error: error,
    );
  }

  void _ensureConnected() {
    if (!_connected || _dbproc == null || _dbproc == nullptr) {
      throw SQLException('Not connected. Call connect() first.');
    }
  }

  static String _normalizeParamName(String name) =>
      name.startsWith('@') ? name : '@$name';

  static String _inferSqlType(dynamic v) {
    // For NULL values, avoid sql_variant which cannot implicitly convert to many types.
    // Use NVARCHAR(MAX) so NULL can bind safely to any nullable target type.
    if (v == null) return 'nvarchar(max)';
    if (v is bool) return 'bit';
    if (v is int) {
      // choose bigint if outside 32-bit range
      if (v < -2147483648 || v > 2147483647) return 'bigint';
      return 'int';
    }
    if (v is double) return 'float';
    if (v is String) return 'nvarchar(max)';
    // Declare DateTime parameters as VARCHAR(50) so it matches the SYBVARCHAR
    // encoding perfectly, allowing SQL Server to explicitly/implicitly convert it.
    if (v is DateTime) return 'varchar(50)';
    if (v is Uint8List) return 'varbinary(max)';
    // Fallback to NVARCHAR
    return 'nvarchar(max)';
  }

  // Analyze whether strict SET options are needed and generate the SET batch.
  _SetPlan _analyzeSetNeeds(String sql) {
    final trimmed = sql.trimLeft();
    if (trimmed.isEmpty) return const _SetPlan(false, '');
    final up = trimmed.toUpperCase();
    final isDdl =
        up.startsWith('CREATE ') ||
        up.startsWith('ALTER ') ||
        up.startsWith('DROP ');
    final targetsStrict =
        up.startsWith('CREATE VIEW ') ||
        up.startsWith('ALTER VIEW ') ||
        up.startsWith('CREATE TABLE ') ||
        up.startsWith('ALTER TABLE ') ||
        up.startsWith('CREATE INDEX ') ||
        up.startsWith('ALTER INDEX ') ||
        up.startsWith('CREATE FUNCTION ') ||
        up.startsWith('ALTER FUNCTION ') ||
        up.startsWith('CREATE PROCEDURE ') ||
        up.startsWith('ALTER PROCEDURE ') ||
        up.startsWith('CREATE TRIGGER ') ||
        up.startsWith('ALTER TRIGGER ');
    if (!(isDdl || targetsStrict)) return const _SetPlan(false, '');
    const setPrefix =
        'SET ANSI_NULLS ON; '
        'SET QUOTED_IDENTIFIER ON; '
        'SET ANSI_PADDING ON; '
        'SET ANSI_WARNINGS ON; '
        'SET CONCAT_NULL_YIELDS_NULL ON; '
        'SET ARITHABORT ON; '
        'SET NUMERIC_ROUNDABORT OFF;';
    return const _SetPlan(true, setPrefix);
  }
}

class _SetPlan {
  final bool needsSet;
  final String setPrefix;
  const _SetPlan(this.needsSet, this.setPrefix);
}

class _TempBuf {
  final Pointer<Uint8> ptr;
  final int length;
  _TempBuf(this.ptr, this.length);
}

class _RpcVal {
  final int type; // DB-Lib type code for dbrpcparam
  final _TempBuf buf;
  _RpcVal(this.type, this.buf);
}

int _hostTypeFor(dynamic v) {
  if (v is int) {
    if (v < -2147483648 || v > 2147483647) return SYBINT8;
    return SYBINT4;
  }
  if (v is double) return SYBFLT8;
  if (v is bool) return SYBBIT;
  if (v is Uint8List) return SYBVARBINARY;
  // NTEXT becomes NVARCHAR(MAX) with TDS 7.2+, avoiding the short VARCHAR RPC path.
  return SYBNTEXT;
}

_TempBuf _encodeForHost(int hostType, dynamic v) {
  switch (hostType) {
    case SYBINT4:
      {
        final p = malloc<Int32>();
        p.value = (v as int);
        return _TempBuf(p.cast<Uint8>(), 4);
      }
    case SYBINT8:
      {
        final p = malloc<Int64>();
        p.value = (v as int);
        return _TempBuf(p.cast<Uint8>(), 8);
      }
    case SYBFLT8:
      {
        final p = malloc<Double>();
        p.value = (v as double);
        return _TempBuf(p.cast<Uint8>(), 8);
      }
    case SYBBIT:
      {
        final p = malloc<Uint8>();
        p.value = (v as bool) ? 1 : 0;
        return _TempBuf(p.cast<Uint8>(), 1);
      }
    case SYBVARBINARY:
      {
        final bytes = (v as Uint8List);
        final p = malloc<Uint8>(bytes.length);
        p.asTypedList(bytes.length).setAll(0, bytes);
        return _TempBuf(p, bytes.length);
      }
    case SYBNTEXT:
      return _encodeText(v.toString());
    default:
      throw ArgumentError('Unsupported FreeTDS host type: $hostType');
  }
}

// Map a Dart value to a DB-Lib type code and native buffer suitable for dbrpcparam.
// For safety and simplicity, most complex types are passed as NVARCHAR and
// converted server-side according to the declared SQL type in sp_executesql.
_RpcVal _encodeForRpc(dynamic v) {
  if (v == null) {
    // Represent NULL by zero-length buffer of any type; server will see NULL
    // when dbrpcparam datalen is 0.
    return _RpcVal(SYBNTEXT, _TempBuf(malloc<Uint8>(0), 0));
  }
  if (v is DateTime) {
    return _RpcVal(SYBVARCHAR, _encodeText(_formatDateTimeForSql(v)));
  }
  final type = _hostTypeFor(v);
  return _RpcVal(type, _encodeForHost(type, v));
}

// Format DateTime into a string accepted by SQL Server for implicit varchar->datetime conversion.
//
// Contract:
// - This function does NOT validate the DateTime value. Validation is the caller's responsibility.
// - Dart's DateTime constructor normalizes out-of-range fields (e.g., month=99 overflows into
//   extra years). The resulting normalized date is formatted and sent as-is.
//   If the resulting value is outside SQL Server's supported DATETIME range
//   (1753-01-01 to 9999-12-31), SQL Server will reject it and the driver will
//   surface a SQLException with the server's error message. No silent truncation occurs.
// - The format 'yyyy-MM-dd HH:mm:ss' (space separator, no fractional seconds) is used
//   because it is unambiguously parsed by SQL Server regardless of DATEFORMAT/locale setting.
//   The ISO8601 'T' separator is intentionally avoided — SQL Server rejects it in implicit
//   varchar->datetime conversions under certain DATEFORMAT configurations.
String _formatDateTimeForSql(DateTime dt) {
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

// Length-delimited values preserve embedded NUL; datalen is always bytes.
_TempBuf _encodeText(String text) {
  final bytes = freeTdsTextCodec.encode(text);
  final p = malloc<Uint8>(bytes.length);
  p.asTypedList(bytes.length).setAll(0, bytes);
  return _TempBuf(p, bytes.length);
}
