import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sql_server_wrapper/src/ffi/freetds_bindings.dart';
import 'package:sql_server_wrapper/src/ffi/freetds_text.dart';
import 'package:sql_server_wrapper/src/mssql_client.dart';
import 'package:sql_server_wrapper/src/native_logger.dart';
import 'package:sql_server_wrapper/src/sql_exception.dart';
import 'package:test/test.dart';

const sample = 'João ação € “aspas” 中文 مرحبا 🙂';

void main() {
  test(
    'failed login exposes callbacks from temporary handles without logs',
    () async {
      final db = _RecordingDb()..failOpen = true;
      final client = _clientWith(db);
      await expectLater(
        client.connect(),
        throwsA(
          isA<SQLException>().having(
            (e) => e.message,
            'diagnostic',
            contains('Login failed for test user'),
          ),
        ),
      );
      expect(client.isConnected, isFalse);
      db.failOpen = false;
      expect(await client.connect(), isTrue);
    },
  );

  test(
    'failed login without callback has fallback and no stale diagnostic',
    () async {
      final db = _RecordingDb()
        ..failOpen = true
        ..emitLoginDiagnostic = false;
      await expectLater(
        _clientWith(db).connect(),
        throwsA(
          isA<SQLException>().having(
            (e) => e.message,
            'diagnostic',
            'dbopen failed.',
          ),
        ),
      );
    },
  );
  test('Dart UTF-16 code units become exact UTF-8 bytes without cleaning', () {
    final text = String.fromCharCodes([
      0x0041,
      0x00e7,
      0x00e3,
      0x006f,
      0xd83d,
      0xde42,
    ]);
    const expected = [
      0x41,
      0xc3,
      0xa7,
      0xc3,
      0xa3,
      0x6f,
      0xf0,
      0x9f,
      0x99,
      0x82,
    ];
    expect(text, 'Ação🙂');
    expect(text.codeUnits, isNot(contains(0)));
    expect(utf8.encode(text), expected);
    expect(freeTdsTextCodec.encode(text), expected);
    using((arena) {
      final pointer = toNativeFreeTdsText(text, allocator: arena);
      // Inspect the complete allocation directly, including the C terminator.
      // No decoder, strlen or NUL removal is involved in this assertion.
      expect(pointer.cast<Uint8>().asTypedList(expected.length + 1), [
        ...expected,
        0,
      ]);
    });
  });

  test('misreading UTF-16LE creates NULs before UTF-8 encoding', () {
    const utf16le = [0x41, 0, 0x42, 0, 0x43, 0];
    // Deliberately use the wrong decoder to reproduce the suspected failure.
    final wrong = utf8.decode(utf16le);
    expect(wrong.codeUnits, [0x41, 0, 0x42, 0, 0x43, 0]);
    expect(utf8.encode(wrong), utf16le);
    expect(freeTdsTextCodec.encode(wrong), utf16le);

    // Actual NUL and the literal characters backslash-x-zero-zero differ.
    expect(utf8.encode('A\u0000B'), [0x41, 0, 0x42]);
    expect(utf8.encode(r'A\x00B'), [0x41, 0x5c, 0x78, 0x30, 0x30, 0x42]);
  });

  test('sets the UTF-8 client charset before opening the connection', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    expect(await client.connect(), isTrue);
    expect(db.loginEvents, ['UTF-8', 'bcp:1:6', 'open']);
  });

  test('does not open a connection when the charset cannot be set', () async {
    final db = _RecordingDb()..charsetResult = FAIL;
    await expectLater(_clientWith(db).connect(), throwsA(isA<SQLException>()));
    expect(db.loginEvents, ['UTF-8']);
  });

  test('SQL, RPC, procedures and text bulk inserts share UTF-8', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();

    final sql = "SELECT N'$sample' AS [Descrição]";
    await client.execute(sql);
    expect(db.commands.last, utf8.encode(sql));
    const ddl = 'CREATE TABLE #Ação (Id INT)';
    await client.execute(ddl);
    expect(db.commands.last, utf8.encode(ddl));

    for (final value in [sample, 'A\u0000BC', List.filled(5000, 'é').join()]) {
      await client.executeParams('SELECT @texto AS [Descrição]', {
        'texto': value,
      });
      expect(db.params.last.type, SYBNTEXT);
      expect(db.params.last.bytes, utf8.encode(value));
      expect(db.params.last.length, utf8.encode(value).length);

      await client.executeProcedure('dbo.Operação', {'texto': value});
      expect(db.procedures.last, 'dbo.Operação');
      expect(db.params.last.type, SYBNTEXT);
      expect(db.params.last.bytes, utf8.encode(value));

      // The native BCP path is deliberately absent from this fake: text must use RPC.
      expect(
        await client.bulkInsert('dbo.Textos', [
          {'Descrição': value},
        ]),
        1,
      );
      expect(db.procedures.last, 'sp_executesql');
      expect(db.params.last.bytes, utf8.encode(value));
      expect(db.params.last.name, '@p0');
    }
  });

  test('RPC keeps numeric, binary and NULL types', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();
    final bytes = Uint8List.fromList([0, 0xff, 0x80]);
    await client.executeProcedure('dbo.Values', {
      'integer': 42,
      'bigint': 1 << 40,
      'boolean': true,
      'float': 1.5,
      'binary': bytes,
      'null': null,
    });
    expect(db.params.map((p) => p.type), [
      SYBINT4,
      SYBINT8,
      SYBBIT,
      SYBFLT8,
      SYBVARBINARY,
      SYBNTEXT,
    ]);
    expect(db.params.map((p) => p.length), [4, 8, 1, 8, 3, 0]);
    expect(db.params[4].bytes, bytes);
  });

  test('numeric and binary loads keep BCP batching', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();
    expect(
      await client.bulkInsert('dbo.Values', [
        {
          'Id': 1,
          'Bytes': Uint8List.fromList([0, 255]),
        },
        {
          'Id': 2,
          'Bytes': Uint8List.fromList([128]),
        },
      ], batchSize: 1),
      2,
    );
    expect(db.bcpRows, 2);
    expect(db.procedures, isEmpty);
  });

  test('text results preserve Unicode and actual NUL characters', () {
    for (final value in [sample, 'A\u0000BC', 'A\u0000n\u0000a']) {
      using((arena) {
        final bytes = utf8.encode(value);
        final pointer = arena<Uint8>(bytes.length);
        pointer.asTypedList(bytes.length).setAll(0, bytes);
        for (final type in [
          SYBCHAR,
          SYBVARCHAR,
          SYBTEXT,
          SYBNTEXT,
          SYBNVARCHAR,
        ]) {
          expect(decodeDbValue(type, pointer, bytes.length), value);
        }
        expect(
          decodeDbValue(SYBVARBINARY, pointer, bytes.length),
          base64Encode(bytes),
        );
      });
    }
  });

  test('invalid UTF-8 fails instead of guessing Latin-1 or UTF-16', () {
    using((arena) {
      final pointer = arena<Uint8>(1)..value = 0xe9;
      expect(
        () => decodeDbValue(SYBVARCHAR, pointer, 1),
        throwsFormatException,
      );
      expect(
        () =>
            tryConvertToString(_RecordingDb(), nullptr, SYBNUMERIC, pointer, 1),
        throwsFormatException,
      );
    });
  });

  test('C strings use UTF-8 and reject NUL instead of truncating SQL', () {
    using((arena) {
      final pointer = toNativeFreeTdsText(sample, allocator: arena);
      expect(fromNativeFreeTdsText(pointer), sample);
      expect(pointer.length, utf8.encode(sample).length);
      expect(
        () => toNativeFreeTdsText(
          'SELECT 1\u0000; DELETE FROM T',
          allocator: arena,
        ),
        throwsArgumentError,
      );
    });
  });

  test('native diagnostics replace invalid UTF-8 without throwing', () {
    using((arena) {
      final text = arena<Uint8>(2);
      text.asTypedList(2).setAll(0, [0xe9, 0]);
      final callback = kMsgHandlerPtr
          .asFunction<
            int Function(
              Pointer<DBPROCESS>,
              int,
              int,
              int,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              int,
            )
          >();
      final logs = <String>[];
      final wasEnabled = MssqlLogger.enabled;
      MssqlLogger.enabled = true;
      try {
        runZoned(
          () => expect(
            callback(nullptr, 1, 0, 16, text.cast(), nullptr, nullptr, 1),
            0,
          ),
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line),
          ),
        );
      } finally {
        MssqlLogger.enabled = wasEnabled;
      }
      expect(logs.single, contains('SQL Server callback'));
      expect(logs.single, endsWith('\uFFFD'));
      expect(DBLib.takeLastMessage(nullptr), endsWith('\uFFFD'));
    });
  });
}

// Exercise the internal client without loading DLLs or contacting a server.
MssqlClient _clientWith(DBLib db) => MssqlClient(
  server: 'codec-test',
  username: 'user',
  password: 'test',
  dbLib: db,
);

class _RecordingDb implements DBLib {
  bool failOpen = false;
  bool emitLoginDiagnostic = true;
  int charsetResult = SUCCEED;
  final loginEvents = <String>[];
  final commands = <List<int>>[];
  final procedures = <String>[];
  final params = <({String name, int type, int length, List<int> bytes})>[];
  bool _result = false;
  int bcpRows = 0;
  int _batchRows = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final Function callback = switch (invocation.memberName) {
      #dbinit => () => SUCCEED,
      #dberrhandle => (dynamic pointer) => kErrHandlerPtr,
      #dbmsghandle => (dynamic pointer) => kMsgHandlerPtr,
      #dbsetlogintime => (dynamic seconds) => SUCCEED,
      #dblogin => () => Pointer<LOGINREC>.fromAddress(1),
      #dbsetlcharset => (dynamic login, Pointer<Utf8> charset) {
        loginEvents.add(charset.toDartString());
        return charsetResult;
      },
      #dbsetluser || #dbsetlpwd => (dynamic login, dynamic text) => SUCCEED,
      #dbsetlbool => (dynamic login, int value, int which) {
        loginEvents.add('bcp:$value:$which');
        return value == 1 && which == DBSETBCP ? SUCCEED : FAIL;
      },
      #dbopen => (dynamic login, dynamic server) {
        loginEvents.add('open');
        if (failOpen) {
          if (emitLoginDiagnostic) {
            using((arena) {
              final callback = kMsgHandlerPtr
                  .asFunction<
                    int Function(
                      Pointer<DBPROCESS>,
                      int,
                      int,
                      int,
                      Pointer<Utf8>,
                      Pointer<Utf8>,
                      Pointer<Utf8>,
                      int,
                    )
                  >();
              callback(
                Pointer<DBPROCESS>.fromAddress(99),
                18456,
                1,
                14,
                toNativeFreeTdsText(
                  'Login failed for test user',
                  allocator: arena,
                ),
                nullptr,
                nullptr,
                1,
              );
            });
          }
          return nullptr.cast<DBPROCESS>();
        }
        return Pointer<DBPROCESS>.fromAddress(2);
      },
      #dbcmd => (dynamic process, Pointer<Utf8> text) {
        commands.add(text.cast<Uint8>().asTypedList(text.length).toList());
        return SUCCEED;
      },
      #dbsqlexec || #dbrpcsend || #dbsqlok => (dynamic process) => SUCCEED,
      #dbresults => (dynamic process) {
        _result = !_result;
        return _result ? SUCCEED : NO_MORE_RESULTS;
      },
      #dbnumcols => (dynamic process) => 0,
      #dbcount => (dynamic process) => 1,
      #bcp_init =>
        (
          dynamic process,
          dynamic table,
          dynamic data,
          dynamic errors,
          dynamic direction,
        ) => SUCCEED,
      #bcp_bind =>
        (
          dynamic process,
          dynamic address,
          dynamic prefix,
          dynamic length,
          dynamic terminator,
          dynamic terminatorLength,
          dynamic type,
          dynamic column,
        ) => SUCCEED,
      #bcp_collen ||
      #bcp_colptr => (dynamic process, dynamic data, dynamic column) => SUCCEED,
      #bcp_sendrow => (dynamic process) {
        bcpRows++;
        _batchRows++;
        return SUCCEED;
      },
      #bcp_batch || #bcp_done => (dynamic process) {
        final rows = _batchRows;
        _batchRows = 0;
        return rows;
      },
      #dbrpcinit => (dynamic process, Pointer<Utf8> name, dynamic options) {
        procedures.add(name.toDartString());
        return SUCCEED;
      },
      #dbrpcparam =>
        (
          dynamic process,
          Pointer<Utf8> name,
          dynamic status,
          int type,
          dynamic maxlen,
          int length,
          Pointer<Uint8> data,
        ) {
          params.add((
            name: name.toDartString(),
            type: type,
            length: length,
            bytes: data.asTypedList(length).toList(),
          ));
          return SUCCEED;
        },
      #dbconvert =>
        (
          dynamic process,
          dynamic sourceType,
          dynamic source,
          dynamic sourceLength,
          dynamic targetType,
          Pointer<Uint8> target,
          dynamic targetLength,
        ) {
          target.value = 0xe9;
          return 1;
        },
      _ => throw StateError(
        'Unexpected DB-Lib operation: ${invocation.memberName}',
      ),
    };
    return invocation.isGetter
        ? callback
        : Function.apply(callback, invocation.positionalArguments);
  }
}
