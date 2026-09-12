/// Column metadata for the current cursor result. [typeCode] is a DB-Lib code.
class SqlColumn {
  final String name;
  final int typeCode;

  const SqlColumn({required this.name, required this.typeCode});
}

/// A decoded row that remains valid after fetching again or closing the cursor.
class SqlRow {
  final List<String> columns;
  final List<dynamic> values;

  SqlRow({required List<String> columns, required List<dynamic> values})
    : columns = List.unmodifiable(columns),
      values = List.unmodifiable(values);

  /// Access by zero-based position or exact column name (first duplicate wins).
  dynamic operator [](Object column) {
    if (column is int) return values[column];
    if (column is String) {
      final index = columns.indexOf(column);
      if (index >= 0) return values[index];
    }
    throw ArgumentError.value(column, 'column', 'Unknown column');
  }

  @override
  String toString() => values.toString();
}
