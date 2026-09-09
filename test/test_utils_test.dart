import 'package:sql_server_wrapper/mssql_connection.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test('response helpers preserve typed values and affected rows', () {
    final response = SqlResponse(
      resultSets: [
        SqlResultSet(
          columns: ['id', 'text', 'optional'],
          rows: [
            [1, 'ação\u0000🙂', null],
          ],
        ),
      ],
      totalAffectedRows: 3,
    );
    expect(parseRows(response), [
      {'id': 1, 'text': 'ação\u0000🙂', 'optional': null},
    ]);
    expect(affectedCount(response), 3);
    expect(
      parseRows(SqlResponse(resultSets: [], totalAffectedRows: 0)),
      isEmpty,
    );
  });

  test('response helpers do not hide SQL errors or extra result sets', () {
    final failure = SqlResponse(
      resultSets: [],
      totalAffectedRows: 0,
      error: 'SQL failed',
    );
    expect(() => parseRows(failure), throwsA(isA<SQLException>()));
    expect(() => affectedCount(failure), throwsA(isA<SQLException>()));
    final set = SqlResultSet(
      columns: ['id'],
      rows: [
        [1],
      ],
    );
    expect(
      () =>
          parseRows(SqlResponse(resultSets: [set, set], totalAffectedRows: 0)),
      throwsStateError,
    );
  });
}
