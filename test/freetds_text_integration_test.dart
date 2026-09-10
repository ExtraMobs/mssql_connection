import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:sql_server_wrapper/mssql_connection.dart';
import 'package:sql_server_wrapper/src/native_logger.dart';
import 'package:test/test.dart';

void main() {
  MssqlLogger.enabled = true;
  NativeLogger.enabled = true;
  final env = Platform.environment;
  final configured = [
    'MSSQL_IP',
    'MSSQL_USER',
    'MSSQL_PASSWORD',
  ].every((key) => env[key]?.isNotEmpty == true);

  test(
    'UTF-8 round trip through SQL, RPC, a procedure and bulkInsert',
    () async {
      final db = MssqlConnection.getInstance();
      if (env['MSSQL_NATIVE_DIR'] != null) {
        NativeLoader.libraryDirectory = env['MSSQL_NATIVE_DIR'];
      }
      const value = 'João ação € “aspas” 中文 مرحبا 🙂';
      final longValue = List.filled(5000, 'é').join();

      SqlResponse checked(SqlResponse response) {
        if (response.error != null) throw SQLException(response.error!);
        return response;
      }

      void expectValue(SqlResponse response, String expected) {
        final set = checked(response).resultSets.single;
        expect(set.rows.single.single, expected);
      }

      try {
        expect(
          await db.connect(
            ip: env['MSSQL_IP']!,
            port: env['MSSQL_PORT'] ?? '1433',
            databaseName: env['MSSQL_DB'] ?? 'tempdb',
            username: env['MSSQL_USER']!,
            password: env['MSSQL_PASSWORD']!,
            caFile: env['MSSQL_CA_FILE'] ?? 'system',
            certificateHostname: env['MSSQL_CERTIFICATE_HOSTNAME'],
          ),
          isTrue,
        );

        final direct = await db.getData("SELECT N'$value' AS [Descrição]");
        expectValue(direct, value);
        expect(direct.resultSets.single.columns, ['Descrição']);

        checked(
          await db.writeData(
            'CREATE TABLE #CodecText (Id INT NOT NULL, Texto NVARCHAR(MAX))',
          ),
        );
        checked(
          await db.writeData(
            'CREATE PROCEDURE #CodecEcho @texto NVARCHAR(MAX) AS SELECT @texto',
          ),
        );

        for (final text in [value, longValue, 'A\u0000BC', '']) {
          expectValue(
            await db.getDataWithParams('SELECT @texto', {'texto': text}),
            text,
          );
          expectValue(
            await db.executeProcedure('#CodecEcho', {'texto': text}),
            text,
          );
          checked(
            await db.writeDataWithParams(
              'INSERT INTO #CodecText (Id, Texto) VALUES (@id, @texto)',
              {'id': 1, 'texto': text},
            ),
          );
          expectValue(
            await db.getData('SELECT Texto FROM #CodecText WHERE Id = 1'),
            text,
          );
          checked(
            await db.writeDataWithParams(
              'UPDATE #CodecText SET Texto = @texto WHERE Id = @id',
              {'id': 1, 'texto': value},
            ),
          );
          expectValue(
            await db.getData('SELECT Texto FROM #CodecText WHERE Id = 1'),
            value,
          );
          checked(await db.writeData('DELETE FROM #CodecText'));

          await db.bulkInsert('#CodecText', [
            {'Id': 2, 'Texto': text},
          ]);
          expectValue(
            await db.getData('SELECT Texto FROM #CodecText WHERE Id = 2'),
            text,
          );
          checked(await db.writeData('DELETE FROM #CodecText'));
        }

        await db.writeData(
          'CREATE PROCEDURE #EmptyValues @a nvarchar(max), @b varbinary(max), @c nvarchar(max) AS SELECT @a, @b, @c',
        );
        final emptyParams = {'a': '', 'b': Uint8List(0), 'c': null};
        expect(
          (await db.getDataWithParams(
            'SELECT @a, @b, @c',
            emptyParams,
          )).resultSets.single.rows.single,
          ['', '', null],
        );
        expect(
          (await db.executeProcedure(
            '#EmptyValues',
            emptyParams,
          )).resultSets.single.rows.single,
          ['', '', null],
        );
        final money = await db.getData(
          "SELECT CAST(1 AS money), CAST(-0.0001 AS money), CAST(12345678901234567890.123456789012345678 AS decimal(38,18))",
        );
        expect(money.resultSets.single.rows.single, [
          '1.0000',
          '-0.0001',
          '12345678901234567890.123456789012345678',
        ]);

        await db.writeData(
          'CREATE PROCEDURE #DateEcho @v datetimeoffset(7) AS SELECT CONVERT(datetime,@v), CONVERT(datetime2(7),@v), @v',
        );
        final instant = DateTime.utc(2024, 2, 29, 12, 34, 56, 123, 456);
        for (final format in ['mdy', 'dmy', 'ymd', 'ydm', 'myd', 'dym']) {
          await db.writeData('SET DATEFORMAT $format');
          for (final response in [
            await db.getDataWithParams(
              'SELECT CONVERT(datetime,@v), CONVERT(datetime2(7),@v), @v',
              {'v': instant},
            ),
            await db.executeProcedure('#DateEcho', {'v': instant}),
          ]) {
            final row = response.resultSets.single.rows.single;
            expect(row[0], '2024-02-29T12:34:56.123333');
            expect(row[1], '2024-02-29T12:34:56.1234560');
            expect(row[2], '2024-02-29T12:34:56.1234560+00:00');
          }
        }

        await db.writeData('CREATE TABLE #Tx (id int)');
        final entered = Completer<void>();
        final release = Completer<void>();
        final transaction = db.transaction((tx) async {
          await tx.writeData('INSERT INTO #Tx VALUES (1)');
          entered.complete();
          await release.future;
        });
        await entered.future;
        var outsideFinished = false;
        final outside = db.getData('SELECT COUNT(*) FROM #Tx').then((r) {
          outsideFinished = true;
          return r;
        });
        try {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(outsideFinished, isFalse);
        } finally {
          release.complete();
        }
        await transaction;
        expect((await outside).resultSets.single.rows.single.single, 1);
        await expectLater(
          db.transaction((tx) async {
            await tx.writeData('INSERT INTO #Tx VALUES (2)');
            throw StateError('Application rollback');
          }),
          throwsStateError,
        );
        expect(
          (await db.getData(
            'SELECT COUNT(*) FROM #Tx',
          )).resultSets.single.rows.single.single,
          1,
        );

        // Certificate rejection is tested against the same configured test server.
        final badIdentity = MssqlConnection();
        try {
          await expectLater(
            badIdentity.connect(
              ip: env['MSSQL_IP']!,
              port: env['MSSQL_PORT'] ?? '1433',
              databaseName: env['MSSQL_DB'] ?? 'tempdb',
              username: env['MSSQL_USER']!,
              password: env['MSSQL_PASSWORD']!,
              caFile: env['MSSQL_CA_FILE'] ?? 'system',
              certificateHostname:
                  'wrong-certificate.sql-server-wrapper.invalid',
            ),
            throwsA(isA<SQLException>()),
          );
          expect(badIdentity.isConnected, isFalse);
        } finally {
          await badIdentity.disconnect();
        }
      } finally {
        // Both objects are local to this session and disappear on disconnect.
        await db.disconnect();
      }
    },
    skip: configured
        ? false
        : 'Set MSSQL_IP, MSSQL_USER and MSSQL_PASSWORD for a test server.',
  );
}
