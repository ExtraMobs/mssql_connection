# mssql

Cliente Flutter/Dart para SQL Server via FFI e FreeTDS 1.5.4 vendorizado. API de execução orientada a cursores, guiada pela documentação oficial do pyodbc: [Cursor](https://github.com/mkleehammer/pyodbc/wiki/Cursor) e [Connection](https://github.com/mkleehammer/pyodbc/wiki/Connection). Não é um driver ODBC nem uma reprodução completa do pyodbc.

## Instalação

O manifesto define `mssql`, versão `0.0.1`, Dart `^3.9.0`. Para usar o checkout:

```yaml
dependencies:
  mssql:
    path: ../mssql_connection
```

```dart
import 'package:mssql/mssql.dart';
```

Somente **Windows x64** está registrado no pacote ativo. Windows ARM64 não foi validado; não há implementação web. Demais plataformas estão arquivadas em `todo/`; consulte [TODO.md](TODO.md). O ponto de entrada `package:mssql/mssql_connection.dart` também está disponível.

## Conexão

```dart
final db = MssqlConnection(); // sessão independente
final connected = await db.connect(
  ip: serverHost,
  port: '1433',
  databaseName: database,
  username: user,
  password: password,
  caFile: absoluteCaPemPath,
  autocommit: false, // padrão: confirmar escritas explicitamente
);
if (!connected) throw StateError('Não foi possível conectar');
```

TLS 1.2+ é obrigatório, sem fallback para texto claro. `trustServerCertificate: false` é o padrão. `true` mantém TLS, mas ignora validação da cadeia e do hostname, inclusive para autoassinados. A integração Windows com essa opção foi testada; CA/hostname com certificado confiável ainda não foram validados de ponta a ponta. Consulte [IMPLEMENTACAO_SEGURANCA.md](IMPLEMENTACAO_SEGURANCA.md).

`caFile` aceita PEM absoluto ou `system`. O armazenamento de confiança do OpenSSL não é necessariamente o do sistema operacional. `certificateHostname` permite informar o nome DNS esperado ao conectar por IP. Não confie automaticamente em certificados apresentados por servidores desconhecidos; não embuta credenciais no código.

A DLL deve conter as extensões FreeTDS vendorizadas. O loader usa caminhos do aplicativo instalado, nunca o diretório de trabalho ou `PATH`. Em desenvolvimento Dart fora do app empacotado, configure `NativeLoader.libraryDirectory` com um diretório absoluto confiável antes do primeiro uso.

## Tudo Pelo Cursor

```dart
final cursor = db.cursor(); // síncrono; ainda não executa SQL
try {
  await cursor.execute(
    'SELECT id, nome FROM dbo.Pessoas WHERE id >= ? ORDER BY id',
    [42],
  );
  await for (final row in cursor) {
    print('${row[0]}: ${row['nome']}');
  }
} finally {
  await cursor.close();
}
```

Sim, o próprio cursor funciona no loop. Em Dart use **`await for`**, não `for` síncrono. `execute` retorna o mesmo cursor após enviar SQL e obter metadados; as linhas são decodificadas conforme os fetches avançam. FreeTDS e rede mantêm buffers internos. Pausar a leitura suspende novos fetches. `break` ou cancelamento da assinatura **não fecha o cursor**: a próxima leitura continua da posição atual. Feche-o em `finally`.

| API do cursor | Contrato |
|---|---|
| `execute(sql, [parameters])` | `Future<MssqlCursor>`; SQL livre, DDL, DML ou `EXEC`. Reutilização descarta resultados anteriores. |
| `executemany(sql, iterable)` | `Future<void>`; consome cada lista/mapa de parâmetros progressivamente, inclusive generators `sync*`. `rowcount = -1`. |
| `fetchone()` | Próxima `SqlRow` ou `null` no fim do resultado atual. |
| `fetchval()` | Primeira coluna da próxima linha; `null` para SQL NULL ou fim. |
| `fetchmany([size])` | Até `size` linhas; padrão `arraysize`, inicialmente 1. Zero retorna `[]`, negativo é rejeitado. |
| `fetchall()` | Lista das linhas restantes do resultado atual, materializada em memória. |
| `nextset()` | Descarta linhas restantes e avança; `false` no fim de todos os resultados. |
| `skipRows(count)` | Descarta até `count` linhas. Nome distinto de `Stream.skip` do Dart. |
| `description` / `columns` | `SqlColumn(name, typeCode)` / nomes; `null` para resultados sem colunas. Não são os sete campos ODBC. |
| `rowcount` | Contagem nativa do resultado atual; `-1` quando desconhecida. Pode ser conhecida só após EOF. |
| `cancel()` | Descarta resultados pendentes, mantendo cursor reutilizável. |
| `close()` | Descarta resultados e fecha o cursor; idempotente. Não confirma nem desfaz a transação. |
| `commit()` / `rollback()` | Atalhos para a transação de toda a conexão, não apenas deste cursor. |

`db.execute(sql, [parameters])` é um atalho que cria e retorna um novo cursor; o consumidor deve fechá-lo. `cursor.fetchStream()` retorna o próprio cursor. Fetches e iteração compartilham posição e não avançam automaticamente para o próximo resultado. Buscar linhas sem resultado com colunas lança `StateError`; SELECT vazio preserva seus metadados.

`SqlRow` contém `values` e `columns` imutáveis, independentes dos buffers nativos. Acesso por índice ou nome exato; em nomes duplicados vence a primeira coluna.

## Transações

**`autocommit: false` é o padrão**, como no pyodbc. SQL Server usa `IMPLICIT_TRANSACTIONS ON`; operações pertinentes, inclusive SELECT sobre tabelas, podem iniciar uma transação. Não é necessário chamar `beginTransaction()`.

```dart
final cursor = db.cursor();
try {
  await cursor.execute('UPDATE dbo.Contas SET saldo=saldo-? WHERE id=?', [10, 1]);
  await cursor.execute('UPDATE dbo.Contas SET saldo=saldo+? WHERE id=?', [10, 2]);
  await db.commit();
} catch (_) {
  await cursor.close(); // libera resultados antes do controle transacional
  if (db.isConnected) await db.rollback();
  rethrow;
} finally {
  await cursor.close();
}
```

Commit/rollback afetam **todos os cursores da mesma conexão**. O modo manual não reserva a conexão para um consumidor: use sessões independentes para unidades de trabalho independentes. `MssqlConnection.getInstance()` continua retornando uma instância compartilhada.

`await db.setAutocommit(true)` confirma trabalho pendente antes de habilitar confirmação automática; `false` reativa o modo manual. `db.autocommit` informa o modo. `close()`/`disconnect()` desfazem trabalho não confirmado e invalidam todos os cursores. Fechar apenas o cursor não termina a transação. Não deixe transações de leitura abertas desnecessariamente.

A extensão `transaction((tx) async { ... })` **exige autocommit=true** e reserva a fila por todo o callback. Sucesso confirma; exceção desfaz. Cursores criados dentro dele fecham ao sair e não podem escapar do escopo. Transações aninhadas, commit/rollback manual e mudanças de conexão/modo dentro dele são rejeitados. Aguarde todas as operações iniciadas no callback.

## Concorrência e Limites

Há múltiplos cursores ociosos ou concluídos, mas somente **um comando com resultados pendentes por sessão**, sem MARS. Executar em outro cursor ou confirmar/desfazer enquanto há resultados pendentes lança `StateError`; consuma todos os resultados, use `cancel()` ou feche o cursor primeiro. Não há espera pelo fechamento de um cursor ocioso. No EOF o leitor consulta apenas os metadados do próximo resultado para saber se pode liberar a sessão, preservando `nextset()`.

Operações são serializadas individualmente; não execute consumidores concorrentes no mesmo cursor. Chamadas FFI continuam bloqueando o isolate. DB-Lib exige um único isolate proprietário por processo, inclusive entre conexões independentes. Para uma UI responsiva, mantenha o cliente inteiro em um isolate dedicado e troque mensagens.

`queryTimeoutSeconds` (30) configura timeout nativo. `maxResultRows` (100.000) e `maxResultBytes` (64 MiB de payload) são limites cumulativos de decodificação por execução, somados entre fetches/resultados. Ajuste-os em `connect()` para volumes maiores; não medem toda memória interna do FreeTDS. Excedê-los fecha a sessão.

Falhas SQL/nativas/de decodificação lançam exceção e invalidam sessão e cursores. Na leitura incremental, linhas anteriores podem já ter sido entregues. Reconecte explicitamente; nunca há repetição automática de escrita. Uma falha durante commit pode deixar seu resultado incerto: confira o estado no servidor antes de repetir a operação.

## Parâmetros, Tipos e Bulk

Use `?` com `List` de valores; os parâmetros seguem por RPC, sem interpolação. Marcadores em strings, identificadores e comentários não são substituídos. Nomes de tabela/coluna não podem ser parametrizados. Mapas com `@nome`, `cursor.executeProcedure(name, params)` e `cursor.bulkInsert(...)` são extensões FreeTDS.

| Tipo | Contrato |
|---|---|
| Texto | UTF-8 no cliente; Unicode no RPC; UTF-8 inválido em resultados lança `FormatException`. |
| `int`, `double`, `bool` | Tipos binários correspondentes; NaN e infinito são rejeitados. |
| MONEY/DECIMAL lidos | Strings decimais exatas. |
| `DateTime` enviado | `datetimeoffset(7)` binário; instante, offset e microssegundos do Dart preservados. |
| Datas lidas | Strings ISO, até sete casas nos tipos modernos; datas sem offset não recebem `Z`. |
| `Uint8List` enviado | Binário; resultados binários em Base64. |

Vazio e NULL são distintos. SQL/nomes/credenciais rejeitam NUL; valores parametrizados preservam NUL. Conversões de datas SQL seguem a semântica do servidor; a matriz completa DATEFORMAT/precisão/fusos ainda precisa de validação.

`cursor.bulkInsert(table, rows, columns: ..., batchSize: ...)` retorna `Future<int>`. Modo manual e transações explícitas usam INSERT parametrizado por linha. BCP só é usado com autocommit, sem transação ativa, para cargas numéricas/binárias não nulas com a ordem completa das colunas. Texto, datas, NULL e tabelas `#` usam RPC. Nesse caminho `batchSize` não agrupa INSERTs. Com autocommit, falhas posteriores podem deixar linhas/batches anteriores confirmados.

## Migração

O pacote foi renomeado de `sql_server_wrapper` para `mssql`. Atualize a dependência e use `import 'package:mssql/mssql.dart';`. Os nomes das classes públicas, incluindo `MssqlConnection`, permanecem iguais.

Esta mudança quebra a API anterior: `getData`, `writeData`, variantes `WithParams`, `queryStream`, `SqlResponse` e `SqlResultSet` foram removidos. Use cursor, fetches, `nextset()` e `rowcount`; procedures/bulk agora pertencem ao cursor. Não há migração de schema.

Além de migrar chamadas, acrescente commit/rollback explícitos ou configure `autocommit: true` quando a confirmação por instrução for intencional, inclusive para CREATE/DROP DATABASE. Callbacks `transaction` existentes precisam de autocommit=true. Não faça rollback de versão com transações abertas: confirme ou desfaça conscientemente e feche a sessão antes de trocar a versão.

Veja [EXAMPLE.md](EXAMPLE.md) para exemplos de uso completos.

## Validação e Bibliotecas

```sh
flutter analyze
dart test test/mssql_cursor_test.dart test/freetds_text_test.dart test/test_utils_test.dart
dart test test/native_library_test.dart
dart test test/mssql_cursor_integration_test.dart
dart test test/freetds_text_integration_test.dart
```

Execute cada suíte nativa em um processo separado, pelo proprietário único dos callbacks. Integrações exigem `MSSQL_IP`, `MSSQL_USER`, `MSSQL_PASSWORD`; opcionais: `MSSQL_PORT`, `MSSQL_DB`, `MSSQL_CA_FILE`, `MSSQL_CERTIFICATE_HOSTNAME`, `MSSQL_NATIVE_DIR`. No servidor de teste autoassinado, habilite explicitamente `MSSQL_TRUST_SERVER_CERTIFICATE=true`. Sem configuração, as integrações são ignoradas.

As integrações acima usam objetos temporários, inclusive uma tabela temporária global para verificar duas sessões. Outros helpers e `tool/integration_db_lifecycle.dart` criam/removem bancos: use somente um servidor destinado a testes. Não execute testes de desempenho como verificação padrão. Preserve `concurrency: 1`/`vm` em `dart_test.yaml`; snapshots em `test/cursor_results.dart` são apenas fixtures da suíte, não API pública. Não inclua `.env` ou credenciais no Git.

Para validar também todas as suítes de API, modos, injeção e funcionalidades avançadas, configure o servidor de testes e `RUN_DB_TESTS=1`. O helper aceita `MSSQL_IP`/`MSSQL_PORT` ou `MSSQL_SERVER=host:porta` e usa as mesmas opções explícitas de TLS. Cada arquivo deve executar em um processo separado:

```powershell
$env:RUN_DB_TESTS = '1'
foreach ($suite in Get-ChildItem test -Filter '*_test.dart') {
  dart test $suite.FullName
  if ($LASTEXITCODE -ne 0) { throw "Falha: $($suite.Name)" }
}
```

Essas suítes criam bancos com nomes únicos, usam autocommit para DDL e removem somente seus próprios bancos no teardown, reconectando explicitamente para limpeza quando uma falha SQL invalidou a sessão. Erros de limpeza fazem o teste falhar. O teste `freetds_legacy_decoder_test.dart` reproduz apenas o decoder histórico, não o contrato atual.

Desempenho é separado e opcional. Para validar todos os cenários com volume limitado:

```powershell
$env:PERF_SIZES = '1000'
dart test test/performance/mssql_connection_performance_test.dart
```

Sem `PERF_SIZES`, o benchmark tenta 1, 5 e 10 milhões de linhas. Isso não é uma verificação rápida nem validação padrão. Medições de uma execução com 1.000 linhas não demonstram desempenho nesses volumes maiores.

`scripts/fetch-openssl.py` fixa OpenSSL 3.5.8 e verifica SHA-256; `scripts/build-openssl.ps1` e `scripts/build-windows.ps1` recompilam o runtime Windows. Scripts de outras plataformas estão em `todo/scripts/`. Revise versão/checksum juntos; não substitua apenas uma DLL por outra ABI. Artefatos CI precisam de incorporação e validação antes de anunciar suporte.

Este projeto deriva de `mssql_connection`; consulte `LICENSE` e as licenças FreeTDS/OpenSSL distribuídas com suas fontes.
