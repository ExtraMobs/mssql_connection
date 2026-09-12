# Exemplos: Cursor e Transações

O pacote é `mssql` (`0.0.1`), conforme `pubspec.yaml`. Os exemplos seguem o modelo de [Cursor](https://github.com/mkleehammer/pyodbc/wiki/Cursor) e [Connection](https://github.com/mkleehammer/pyodbc/wiki/Connection) do pyodbc, adaptado aos `Future`/`Stream` do Dart. Consulte [README.md](README.md) para instalação, TLS e limitações de plataforma.

## Exemplo Completo

Este exemplo usa somente uma tabela temporária da sessão. Credenciais são obrigatórias no ambiente e não são impressas.

```dart
import 'dart:io';
import 'package:mssql/mssql.dart';

Future<void> main() async {
  final env = Platform.environment;
  String required(String key) =>
      env[key] ?? (throw StateError('Configure $key'));
  final db = MssqlConnection();
  try {
    final connected = await db.connect(
      ip: required('MSSQL_IP'),
      port: env['MSSQL_PORT'] ?? '1433',
      databaseName: env['MSSQL_DB'] ?? 'tempdb',
      username: required('MSSQL_USER'),
      password: required('MSSQL_PASSWORD'),
      caFile: env['MSSQL_CA_FILE'] ?? 'system',
      certificateHostname: env['MSSQL_CERTIFICATE_HOSTNAME'],
      trustServerCertificate:
          env['MSSQL_TRUST_SERVER_CERTIFICATE'] == 'true',
      autocommit: false, // também é o padrão quando omitido
    );
    if (!connected) throw StateError('Falha ao conectar');

    final cursor = db.cursor(); // não precisa de await
    try {
      await cursor.execute(
        'CREATE TABLE #Pessoas (id int PRIMARY KEY, nome nvarchar(100))',
      );
      await cursor.executemany(
        'INSERT INTO #Pessoas (id, nome) VALUES (?, ?)',
        [[1, 'Ana'], [2, 'Bruno'], [3, 'Carla']],
      );
      await db.commit();

      await cursor.execute(
        'SELECT id, nome FROM #Pessoas WHERE id >= ? ORDER BY id',
        [1],
      );
      await for (final row in cursor) {
        print('${row[0]}: ${row['nome']}');
      }

      await cursor.execute(
        'UPDATE #Pessoas SET nome=? WHERE id=?', ['Beatriz', 2],
      );
      print('Linhas afetadas: ${cursor.rowcount}');
      await db.rollback(); // desfaz a atualização, não os INSERTs confirmados
    } catch (_) {
      await cursor.close();
      if (db.isConnected) await db.rollback();
      rethrow;
    } finally {
      await cursor.close();
    }
  } finally {
    await db.close(); // desfaz qualquer transação ainda não confirmada
  }
}
```

## Loop e Fetches

Nos trechos seguintes, `db` é uma conexão já aberta. O cursor é o objeto percorrido: use `await for`, não um `for` síncrono. Não é necessário chamar `fetchone()` manualmente dentro do loop.

```dart
final cursor = await db.execute('SELECT id, nome FROM dbo.Pessoas ORDER BY id');
try {
  await for (final row in cursor) {
    print(row['nome']);
    break;
  }
  // break NÃO fecha o cursor. Este fetch continua da próxima linha.
  final proxima = await cursor.fetchone();
  print(proxima?.values);
} finally {
  await cursor.close();
}
await db.rollback(); // encerra eventual transação de leitura
```

`db.execute()` cria um cursor e retorna `Future<MssqlCursor>`; `cursor.execute()` reutiliza o cursor e retorna o próprio objeto. Ambos aceitam SELECT, INSERT, UPDATE, DELETE, DDL e EXEC. Executar novamente no mesmo cursor descarta os resultados anteriores.

```dart
final cursor = db.cursor();
try {
  await cursor.execute('SELECT id, nome FROM dbo.Pessoas ORDER BY id');
  cursor.arraysize = 100;
  while (true) {
    final lote = await cursor.fetchmany();
    if (lote.isEmpty) break;
    for (final row in lote) {
      print(row.values);
    }
  }
} finally {
  await cursor.close();
}
```

`fetchone()` retorna `null` no fim; `fetchmany([size])` retorna `[]`. `fetchall()` materializa apenas as linhas restantes do resultado atual. Todos compartilham posição com o loop. `fetchval()` retorna a primeira coluna da próxima linha, ou `null` para SQL NULL/fim. `skipRows(n)` descarta até `n` linhas; `Stream.skip(n)` continua sendo a operação de stream do Dart.

As linhas são `SqlRow`: `row[0]`, `row['nome']`, `row.values`, `row.columns`. Valores e nomes são imutáveis e permanecem válidos depois de fechar o cursor. Nomes são exatos; duplicados usam a primeira coluna.

## Vários Resultados e Procedures

```dart
final cursor = db.cursor();
try {
  await cursor.execute('SELECT 1 AS primeiro; SELECT 2 AS segundo');
  do {
    if (cursor.description != null) {
      print(cursor.columns);
      await for (final row in cursor) {
        print(row.values);
      }
    }
    print('Contagem: ${cursor.rowcount}');
  } while (await cursor.nextset());
} finally {
  await cursor.close();
}
```

`nextset()` descarta linhas não lidas do resultado atual. Fetches não avançam automaticamente entre resultados. `description` contém apenas `SqlColumn.name` e o `typeCode` DB-Lib, não os sete campos ODBC; fica `null` para resultados sem colunas. SELECT vazio mantém seus metadados. `rowcount` pode ser `-1` (desconhecido), especialmente antes de terminar um SELECT. Leia-o antes de avançar para outro resultado.

```dart
final cursor = db.cursor();
try {
  await cursor.execute('EXEC dbo.BuscarPessoa @id=?', [42]);
  do {
    if (cursor.description != null) {
      await for (final row in cursor) {
        print(row.values);
      }
    }
  } while (await cursor.nextset());
} finally {
  await cursor.close();
}
```

Também existe `cursor.executeProcedure('dbo.BuscarPessoa', {'id': 42})`, extensão de RPC direto. Procedures que escrevem participam da transação da conexão; confirme-as explicitamente no modo manual.

## Parâmetros e Generators

Use uma `List` com os valores dos marcadores `?`, sem interpolação de dados no SQL. Aspas, colchetes e comentários não contam como marcadores. Nomes de tabelas/colunas não são valores parametrizáveis.

```dart
Iterable<List<Object?>> pessoas() sync* {
  yield [1, 'Ana'];
  yield [2, 'Bruno'];
}

final cursor = db.cursor();
try {
  await cursor.executemany(
    'INSERT INTO dbo.Pessoas (id, nome) VALUES (?, ?)', pessoas(),
  );
  await db.commit();
} catch (_) {
  await cursor.close();
  if (db.isConnected) await db.rollback();
  rethrow;
} finally {
  await cursor.close();
}
```

`executemany` consome o iterable progressivamente, sem convertê-lo inteiro em lista, mas executa as chamadas nativas no isolate proprietário. Retorna `Future<void>` e deixa `rowcount=-1`; não agrega resultados. Com autocommit=true, linhas anteriores podem permanecer confirmadas se uma posterior falhar.

Mapas nomeados continuam disponíveis como extensão: `await cursor.execute('SELECT @id AS id', {'id': 42})`. Não misture lista posicional e mapa na mesma chamada. Nomes duplicados como `id`/`@ID` são rejeitados.

Strings usam UTF-8/Unicode, inclusive NUL em valores parametrizados; SQL/nomes/credenciais rejeitam NUL. `''` é diferente de `null`. `DateTime` usa `datetimeoffset(7)`, preservando instante, offset e microssegundos. Datas lidas são strings ISO; datas sem offset não recebem `Z`. MONEY/DECIMAL retornam strings exatas. Envie binários como `Uint8List`; binários lidos são Base64.

## Transações Compartilhadas

`autocommit` pertence à conexão, assim como a transação. Não há transação privada por cursor nem `beginTransaction()` obrigatório.

```dart
final primeiro = db.cursor();
final segundo = db.cursor();
try {
  await primeiro.execute('UPDATE dbo.Contas SET saldo=saldo-? WHERE id=?', [10, 1]);
  await segundo.execute('UPDATE dbo.Contas SET saldo=saldo+? WHERE id=?', [10, 2]);
  await segundo.commit(); // confirma AMBOS; equivalente a db.commit()
} catch (_) {
  await primeiro.close();
  await segundo.close();
  if (db.isConnected) await db.rollback();
  rethrow;
} finally {
  await primeiro.close();
  await segundo.close();
}
```

`await db.setAutocommit(true)` **confirma trabalho pendente** antes de ativar a confirmação por instrução. `await db.setAutocommit(false)` volta ao modo manual. Leia `db.autocommit` para consultar o modo. CREATE/DROP DATABASE exigem autocommit=true. Não altere `IMPLICIT_TRANSACTIONS` manualmente por SQL: use a API para manter o estado coerente.

Fechar um cursor não confirma nem desfaz escritas. `await db.close()` (ou `disconnect()`) desfaz transações pendentes e invalida todos os cursores. SELECT sobre tabelas também pode iniciar uma transação: encerre-a quando terminar a unidade de trabalho. Falhas nativas invalidam a sessão; não há reconexão/repetição automática.

A extensão de callback abaixo requer uma conexão aberta com `autocommit: true`:

```dart
await db.transaction((tx) async {
  final cursor = tx.cursor();
  await cursor.execute('UPDATE dbo.Contas SET saldo=saldo-? WHERE id=?', [10, 1]);
  await cursor.execute('UPDATE dbo.Contas SET saldo=saldo+? WHERE id=?', [10, 2]);
}); // sucesso confirma; exceção desfaz; cursores do callback fecham ao sair
```

O callback reserva a fila inclusive entre `await`s. Operações externas aguardam; aninhamento e commit/rollback manual dentro dele são rejeitados. Não use seus cursores fora do escopo. No modo manual, consumidores da mesma conexão participam da mesma transação; prefira `MssqlConnection()` independente para trabalhos independentes.

## Bulk Insert

```dart
final cursor = db.cursor();
try {
  final inseridas = await cursor.bulkInsert(
    'dbo.Pessoas',
    [{'id': 10, 'nome': 'Ana'}, {'id': 11, 'nome': 'Bruno'}],
    columns: ['id', 'nome'],
    batchSize: 1000,
  );
  await db.commit();
  print(inseridas);
} catch (_) {
  await cursor.close();
  if (db.isConnected) await db.rollback();
  rethrow;
} finally {
  await cursor.close();
}
```

É uma extensão FreeTDS, com retorno `Future<int>`. No modo manual ou em transação explícita, usa INSERT parametrizado por linha para preservar rollback. Texto, datas, NULL, objetos convertidos em texto e tabelas `#` também usam esse caminho, que não agrupa instruções com `batchSize` e pode ser mais lento. BCP exige autocommit, ausência de transação ativa e dados numéricos/binários não nulos na ordem completa das colunas.

## Limites e Encerramento

Múltiplos cursores ociosos/concluídos podem coexistir. Há somente um comando com resultados pendentes por conexão, sem MARS. Antes de outro cursor executar, de commit/rollback ou de mudar o modo, consuma **todos** os resultados, cancele ou feche o cursor ativo. Caso contrário recebe `StateError`, sem invalidar a sessão. Reutilizar o próprio cursor descarta seu resultado anterior.

Ao consumir EOF, o leitor verifica apenas os metadados do próximo resultado. Se não houver outro, libera a sessão sem exigir fechar o cursor; se houver, use `nextset()` ou descarte-o. `cursor.cancel()` preserva o cursor. `close()` é idempotente. Uma pausa no stream suspende fetches; `break` não fecha o cursor. Não use consumidores concorrentes no mesmo cursor.

`maxResultRows` (100.000) e `maxResultBytes` (64 MiB) contam dados decodificados por execução, somados entre fetches e resultados; não medem todos os buffers nativos. Ajuste-os em `connect()` para volumes maiores. Ultrapassá-los, SQL inválido ou falha nativa/de decodificação fecha a sessão; linhas anteriores podem já ter sido entregues. Não trate uma leitura interrompida como completa. Uma falha de comunicação durante commit pode ter resultado incerto.

Todas as chamadas DB-Lib do processo devem ficar no mesmo isolate proprietário. As chamadas FFI bloqueiam esse isolate, apesar dos retornos `Future`/`Stream`. Use um isolate dedicado quando necessário e não exponha o mesmo cursor a consumidores simultâneos.

## Migração e Testes

`getData`/`writeData`/`WithParams`/`queryStream` e `SqlResponse`/`SqlResultSet` saíram da API. Troque por `cursor.execute`, fetches/loop, `nextset` e `rowcount`. Procedures/bulk pertencem ao cursor. Feche o cursor explicitamente e revise todas as escritas para commit/rollback ou autocommit=true. Não há alteração de schema. Antes de trocar de versão, encerre conscientemente transações pendentes e feche as sessões.

```sh
flutter analyze
dart test test/mssql_cursor_test.dart test/freetds_text_test.dart test/test_utils_test.dart
dart test test/native_library_test.dart
dart test test/mssql_cursor_integration_test.dart
dart test test/freetds_text_integration_test.dart
```

Suítes nativas devem executar separadamente. Integrações usam servidor de testes explicitamente configurado; sem `MSSQL_IP`, `MSSQL_USER`, `MSSQL_PASSWORD`, são ignoradas. Preserve testes seriais na VM. `test/cursor_results.dart` materializa snapshots apenas para fixtures de testes, não para a API pública. Os demais helpers de banco e `tool/integration_db_lifecycle.dart` podem criar/remover bancos; não os execute contra produção nem rode desempenho como verificação padrão.
