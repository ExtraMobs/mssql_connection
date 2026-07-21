# MSSQL Connection Plugin

The `mssql_connection` plugin allows Flutter applications to seamlessly connect to and interact with Microsoft SQL Server databases, offering rich functionality for querying and data manipulation.

🚀 Now powered by Dart FFI + FreeTDS with support for Windows, Android, iOS, macOS, and Linux. Simplify SQL Server access with a small, consistent API. 🔗

---

## Features

- 🔄 **Cross-Platform (FFI + FreeTDS)**: Windows, Android, iOS, macOS, Linux.
- 📊 **Native ResultSet**: Strongly-typed `SqlResponse` for fast and safe access to reads/writes without manual JSON parsing.
- 🔒 **Parameterized Queries**: Call with `getDataWithParams`/`writeDataWithParams` to reduce injection risk.
- 🔧 **Transactions**: `beginTransaction`, `commit`, `rollback`.
- � **Bulk Insert**: High-throughput inserts using FreeTDS BCP.
- ⏳ **Timeouts + Reconnect**: Login timeout and auto-reconnect on demand.

---

## Installation

To use the MsSQL Connection plugin in your Flutter project, follow these simple steps:

1. **Add Dependency**:
   Open your `pubspec.yaml` file and add the following:

   ```yaml
   dependencies:
     mssql_connection: ^3.0.0
   ```

   Replace `^3.0.0` with the latest version.

2. **Install Packages**:
   Run the following command to fetch the plugin:

   ```bash
   flutter pub get
   ```

3. **Import the Plugin**:
   Include the plugin in your Dart code:

   ```dart
   import 'package:mssql_connection/mssql_connection.dart';
   ```

4. **Initialize Connection**:
   Get an instance of `MssqlConnection`:

   ```dart
   MssqlConnection mssqlConnection = MssqlConnection.getInstance();
   ```

---

## Usage/Examples

### Example Screenshots
<img src="https://github.com/Hiteshdon/mssql_connection/blob/f58ae81722cd6472d2e574913b54230c0467f6e5/images/image1.png?raw=true" alt="Connection Establishing Screen" width="300"/>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<img src="https://github.com/Hiteshdon/mssql_connection/blob/f58ae81722cd6472d2e574913b54230c0467f6e5/images/image2.png?raw=true" alt="Read & Write Operations Screen" width="300"/>

---

### **Connect to Database**

Establish a connection to the Microsoft SQL Server using the `connect` method with customizable parameters:

```dart
bool isConnected = await mssqlConnection.connect(
  ip: 'your_server_ip',
  port: 'your_server_port',
  databaseName: 'your_database_name',
  username: 'your_username',
  password: 'your_password',
  timeoutInSeconds: 15,
);

// `isConnected` returns true if the connection is established.
```

---

### **Get Data**

Fetch data from the database using the `getData` method:

```dart
String query = 'SELECT * FROM your_table';
SqlResponse result = await mssqlConnection.getData(query);

// `result` contains strongly-typed resultSets natively.
print(result.resultSets.first.columns);
print(result.resultSets.first.rows);
```

---

### **Write Data**

Perform insert, update, or delete operations using the `writeData` method:

```dart
String query = 'UPDATE your_table SET column_name = "new_value" WHERE condition';
SqlResponse result = await mssqlConnection.writeData(query);

// `result.totalAffectedRows` contains details about the operation.
print('Affected rows: ${result.totalAffectedRows}');
```

---

### Parameterized queries

Avoid manual string concatenation and let the library pass parameters safely via `sp_executesql`:

```dart
final res = await mssqlConnection.getDataWithParams(
  'SELECT * FROM Users WHERE Name LIKE @name AND IsActive = @active',
  {
    'name': '%john%',
    'active': true,
  },
);
```

---

### Transactions

```dart
await mssqlConnection.beginTransaction();
try {
  await mssqlConnection.writeData('UPDATE Accounts SET Balance = Balance - 100 WHERE Id = 1');
  await mssqlConnection.writeData('UPDATE Accounts SET Balance = Balance + 100 WHERE Id = 2');
  await mssqlConnection.commit();
} catch (_) {
  await mssqlConnection.rollback();
  rethrow;
}
```

---

### Bulk insertion

```dart
final rows = [
  {'Id': 1, 'Name': 'Alice'},
  {'Id': 2, 'Name': 'Bob'},
];
int insertedCount = await mssqlConnection.bulkInsert('dbo.Users', rows, batchSize: 1000);
print('Rows inserted: $insertedCount');
```

---

### **Execute Stored Procedures (RPC)**

Execute chamadas de Stored Procedures de forma direta e segura através do protocolo RPC, utilizando o método `executeProcedure`:

```dart
final response = await mssqlConnection.executeProcedure(
  'dbo.PROC_GetUserDetails',
  {
    'UserId': 123,
    'IsActive': true,
  },
);
```

---

### **Disconnect**

Close the database connection when it's no longer needed:

```dart
bool isDisconnected = await mssqlConnection.disconnect();

// `isDisconnected` returns true if the connection was successfully closed.
```

---

## 🔄 Version 3.0.0 Highlights

- Cross-platform via Dart FFI + FreeTDS (Windows/Android/iOS/macOS/Linux).
- Native typed `SqlResponse` and Python-style ResultSets for reads/writes.
- Parameterized queries, transactions, RPC Stored Procedures, and bulk insertion.

---

## 🔐 Binary Data Handling (`VARBINARY`, `BLOB`, `BINARY`)

This plugin automatically handles binary columns like `VARBINARY`, `BLOB`, and `BINARY` by **Base64 encoding** their contents in the output.

### 🧪 Example

**SQL Query:**

```sql
INSERT INTO Files (FileName, Data)
VALUES ('example.txt', CAST('This is some binary data' AS VARBINARY(MAX)));
```

**Flutter Output (`SqlResponse.resultSets`):**

```dart
[
  [1, "example.txt", "VGhpcyBpcyBzb21lIGJpbmFyeSBkYXRh"]
]
```

### 📥 Decoding in Flutter

You can decode this data like this:

```dart
import 'dart:convert';

final base64Str = "VGhpcyBpcyBzb21lIGJpbmFyeSBkYXRh";
final bytes = base64Decode(base64Str);

// If the binary is actually plain text, decode it further
final decodedText = utf8.decode(bytes);
print(decodedText); // Output: This is some binary data
```

> ⚠️ **Note**: Always decode the binary based on its original intent—whether it's a file, an image, or plain text.

---

## Contributing

Contributions to improve this plugin are welcome! To contribute:

1. Fork the repository.
2. Create a feature branch for your changes.
3. Commit your changes with clear, concise messages.
4. Push the branch and create a pull request.

For issues, suggestions, or feature requests, feel free to open an issue in the repository. Thank you for contributing to `mssql_connection`! 🚀

---