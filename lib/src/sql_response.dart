class SqlResultSet {
  final List<String> columns;
  final List<List<dynamic>> rows;

  SqlResultSet({
    required this.columns,
    required this.rows,
  });
}

class SqlResponse {
  final List<SqlResultSet> resultSets;
  final int totalAffectedRows;
  final String? error;

  SqlResponse({
    required this.resultSets,
    required this.totalAffectedRows,
    this.error,
  });
}
