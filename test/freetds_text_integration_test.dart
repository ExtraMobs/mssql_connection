import 'dart:io';

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

        for (final text in [value, longValue, 'A\u0000BC']) {
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
