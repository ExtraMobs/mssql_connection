# Exemplos de uso

API atual do pacote `sql_server_wrapper` (`0.0.1`). Os trechos Dart com `await` devem ficar dentro de uma função `async`. Eles usam a conexão `db` abaixo; tabelas e procedures devem existir no seu banco.

## Conectar

```dart
import 'package:sql_server_wrapper/mssql_connection.dart';

final MssqlConnection db = MssqlConnection.getInstance();

try {
  final bool conectado = await db.connect(
    ip: '127.0.0.1',
    port: '1433', // String
    databaseName: 'MinhaBase',
    username: 'usuario',
    password: 'sua_senha',
    timeoutInSeconds: 15, // int; timeout de conexão/login
  );
  if (!conectado) throw StateError('Entrada inválida ou servidor inacessível.');
} on SQLException catch (e) {
  // Inclui a operação e os diagnósticos nativos disponíveis.
  // Registre em local protegido; mensagens podem identificar usuário/servidor.
  print(e.message);
  rethrow; // não prossiga com consultas após a falha
}
```

`connect` retorna `Future<bool>`: após `await`, `true` indica conexão estabelecida. Entradas inválidas ou falha na sondagem TCP retornam `false`. Falhas nativas na inicialização/login lançam `SQLException` com os diagnósticos dos callbacks, mesmo com logs desligados; se não houver diagnóstico, a mensagem identifica a operação que falhou. A exceção é lançada após o retorno nativo, nunca dentro do callback FFI. Requer SQL Server acessível e FreeTDS com suas dependências nativas disponíveis.

## Métodos e retornos

| Método | Tipo retornado | Valor após `await` |
|---|---|---|
| `connect(...)` | `Future<bool>` | Estado do estabelecimento da conexão |
| `getData(sql)` | `Future<SqlResponse>` | Resultados do SQL |
| `getDataWithParams(sql, params)` | `Future<SqlResponse>` | Resultados do SQL parametrizado |
| `writeData(sql)` | `Future<SqlResponse>` | Resultados e contagem de linhas afetadas |
| `writeDataWithParams(sql, params)` | `Future<SqlResponse>` | Resultados e contagem do SQL parametrizado |
| `executeProcedure(nome, params)` | `Future<SqlResponse>` | Resultados da procedure |
| `bulkInsert(tabela, linhas, ...)` | `Future<int>` | Quantidade inserida reportada pelo driver |
| `beginTransaction()`, `commit()`, `rollback()` | `Future<void>` | Sem valor de retorno |
| `disconnect()` | `Future<bool>` | Resultado do encerramento pela API |
| `isConnected` | `bool` | Propriedade síncrona; não usa `await` |

`getData` e `writeData` chamam a mesma execução internamente. Os nomes expressam a intenção; não restringem o SQL a leitura ou escrita. O mesmo vale para as versões `WithParams`.

## Estrutura de `SqlResponse`

| Campo | Tipo | Conteúdo |
|---|---|---|
| `resultSets` | `List<SqlResultSet>` | Conjuntos retornados com colunas |
| `totalAffectedRows` | `int` | Soma das contagens reportadas pelo FreeTDS |
| `error` | `String?` | Erro de coleta, quando registrado; `null` caso contrário |
| `resultSets[i].columns` | `List<String>` | Nomes das colunas, em ordem |
| `resultSets[i].rows` | `List<List<dynamic>>` | Linhas; cada posição corresponde a uma coluna |

O retorno é um objeto Dart, sem necessidade de `jsonDecode`. As células são `dynamic`, não modelos tipados nem mapas por nome de coluna. Para contar linhas de um SELECT, use `rows.length`; `totalAffectedRows` depende das contagens do servidor, de `SET NOCOUNT` e dos comandos executados, podendo incluir valores negativos do driver.

Falhas podem lançar `SQLException` ou aparecer em `response.error`. Nos exemplos seguintes, use este helper para conferir o segundo caso:

```dart
SqlResponse conferir(SqlResponse response) {
  final String? erro = response.error;
  if (erro != null) throw SQLException(erro);
  return response;
}
```

## SELECT: consultar linhas

```dart
final SqlResponse resultado = conferir(await db.getDataWithParams(
  'SELECT Id, Nome FROM dbo.Usuarios WHERE Id = @id',
  <String, dynamic>{'id': 1},
));

for (final SqlResultSet conjunto in resultado.resultSets) {
  for (final List<dynamic> linha in conjunto.rows) {
    final int id = linha[0] as int; // supondo coluna SQL INT NOT NULL
    final String? nome = linha[1] as String?;
    print('$id: $nome');
  }
}
```

Exemplo de conteúdo: `columns = ['Id', 'Nome']`, `rows = [[1, 'Ana']]`. Sem registros, `rows` fica vazia. Não acesse `rows.first` sem conferir.

Para SQL fixo sem parâmetros:

```dart
final SqlResponse resultado = conferir(await db.getData(
  'SELECT TOP (10) Id, Nome FROM dbo.Usuarios ORDER BY Id',
));
```

## INSERT: inserir uma linha

```dart
final SqlResponse resultado = conferir(await db.writeDataWithParams(
  'INSERT INTO dbo.Usuarios (Nome) VALUES (@nome)',
  {'nome': 'Ana'},
));
final int afetadas = resultado.totalAffectedRows;
```

O retorno não é o ID criado. Para receber o ID de uma coluna `IDENTITY`, peça-o no SQL:

```dart
final SqlResponse resultado = conferir(await db.writeDataWithParams(
  'INSERT INTO dbo.Usuarios (Nome) OUTPUT INSERTED.Id VALUES (@nome)',
  {'nome': 'Ana'},
));
final int id = resultado.resultSets.first.rows.first[0] as int;
```

Esse acesso pressupõe um INSERT bem-sucedido de uma linha com `Id` do tipo SQL `INT`.

## UPDATE: alterar linhas existentes

```dart
final SqlResponse resultado = conferir(await db.writeDataWithParams(
  'UPDATE dbo.Usuarios SET Nome = @nome WHERE Id = @id',
  {'nome': 'Maria', 'id': 1},
));
final int afetadas = resultado.totalAffectedRows;
```

Retorna `SqlResponse`, não `bool`. Contagem zero pode significar que nenhum registro correspondeu ao filtro; não é, por si só, um erro. Sem `WHERE`, o UPDATE alcança todas as linhas.

## DELETE: remover linhas

```dart
final SqlResponse resultado = conferir(await db.writeDataWithParams(
  'DELETE FROM dbo.Usuarios WHERE Id = @id',
  {'id': 1},
));
final int afetadas = resultado.totalAffectedRows;
```

Remove registros e mantém a tabela. Sem `WHERE`, alcança todas as linhas. Normalmente não retorna linhas; `OUTPUT DELETED.Id` permite recebê-las em `resultSets`. UPDATE também aceita `OUTPUT INSERTED...`/`DELETED...`.

## CREATE, ALTER, DROP e TRUNCATE

```dart
final SqlResponse resultado = conferir(await db.writeData(
  'CREATE TABLE #Itens (Id INT NOT NULL, Nome NVARCHAR(100) NULL)',
));
```

| SQL | Diferença |
|---|---|
| `CREATE TABLE` | Cria a estrutura |
| `ALTER TABLE` | Modifica a estrutura |
| `DELETE ... WHERE ...` | Remove registros selecionados |
| `TRUNCATE TABLE` | Esvazia a tabela inteira, sem `WHERE`, com restrições próprias do SQL Server |
| `DROP TABLE` | Remove a tabela e seus dados |

Todos podem ser enviados por `writeData` e retornam `Future<SqlResponse>`. Comandos de estrutura normalmente não têm linhas de resultado; sua contagem não é um indicador útil de sucesso.

## Parâmetros e tipos de entrada

`WithParams` recebe `String` e `Map<String, dynamic>` e executa via `sp_executesql`. Use placeholders como `@id`; as chaves do mapa aceitam `'id'` ou `'@id'`. Parâmetros representam valores, não nomes de tabela/coluna nem trechos SQL. Não concatene entrada do usuário no SQL.

| Valor Dart | Tipo SQL inferido em `WithParams` |
|---|---|
| `int` | `int`, ou `bigint` fora do intervalo de 32 bits |
| `double` | `float` |
| `bool` | `bit` |
| `String` | `nvarchar(max)`; buffer UTF-8 e parâmetro RPC Unicode |
| `DateTime` | `varchar(50)`, formatado como `yyyy-MM-dd HH:mm:ss` |
| `Uint8List` | `varbinary(max)` |
| `null` | `nvarchar(max)` com valor nulo |

O codec do cliente é UTF-8 em todos os caminhos de texto e é configurado no login do FreeTDS. O driver faz a conversão para a codificação do SQL Server; colunas `VARCHAR` continuam limitadas pela collation. Prefira `NVARCHAR` para texto Unicode e `N'...'` em literais SQL fixos. O envio de UTF-8 não muda a collation do banco.

O módulo `lib/src/ffi/freetds_text.dart` mantém `Utf8Codec()` para os bytes e o identificador nativo `UTF-8` para o login. Não substitua esse identificador por `Utf8Codec().name`: o Dart retorna `utf-8`, alias não reconhecido pela tabela sensível a maiúsculas do FreeTDS vendorizado. Strings Dart usam unidades UTF-16; a conversão padrão para UTF-8 não introduz NUL entre letras. A conversão para UTF-16 do protocolo é responsabilidade do FreeTDS, não do chamador.

Passe strings normalmente; não faça pré-conversão nem remova zeros:

```dart
final String texto = 'João 中文 🙂';
final SqlResponse resposta = conferir(await db.getDataWithParams(
  'SELECT @texto AS Texto',
  {'texto': texto},
));
final String recebido = resposta.resultSets.single.rows.single.single as String;
assert(recebido == texto);
```

Resultados inválidos em UTF-8 lançam `FormatException`, sem tentar Latin-1 ou adivinhar UTF-16. Valores parametrizados preservam `\x00` reais; SQL, nomes e credenciais em C strings rejeitam NUL para evitar truncamento. Dados já corrompidos no banco não são reparados automaticamente. Diagnósticos nativos usam o mesmo UTF-8, com substituição de bytes inválidos por U+FFFD para não lançar através de callbacks.

Limitações atuais: `DateTime` perde frações de segundo e não é convertido para UTC. A conversão de datas para o tipo SQL de destino deve ser validada na configuração do servidor. Outros objetos passam por `toString()`; prefira os tipos acima.

## Tipos das células retornadas

| Tipo SQL comum | Valor Dart atual |
|---|---|
| Inteiros | `int` |
| `bit` | `bool` |
| `real`, `float`, `money`, `smallmoney` | `double` |
| Texto | `String` |
| `datetime`, `smalldatetime` | `String` em formato ISO, não `DateTime` |
| Binários (`binary`, `varbinary`, `image`) | `String` Base64, não `Uint8List` |
| `NULL` | `null` |

Outros tipos usam conversões do FreeTDS e fallbacks; não assuma um cast sem verificar o resultado, especialmente para decimal e tipos de data mais recentes. Conversões numéricas para `double` podem perder precisão. O decoder atual também trata buffers de tamanho zero como `null`.

```dart
import 'dart:convert';
import 'dart:typed_data';

// Se a célula binária não for nula:
final Uint8List bytes = base64Decode(valorBase64);
// Se a célula contiver uma data ISO válida:
final DateTime data = DateTime.parse(valorData);
```

`valorBase64` e `valorData` representam strings obtidas das células correspondentes.

## Stored procedure

```dart
final SqlResponse resultado = conferir(await db.executeProcedure(
  'dbo.BuscarUsuario',
  {'Id': 1},
));
```

A procedure deve existir e aceitar os parâmetros informados. A chamada usa RPC direto. Os SELECTs da procedure aparecem em `resultSets`; escritas contribuem para a contagem reportada. A API atual não oferece campos específicos para parâmetros `OUTPUT` ou código `RETURN` da procedure.

## Vários conjuntos de resultado

```dart
final SqlResponse resultado = conferir(await db.getData(
  'SELECT 1 AS Numero; SELECT 2 AS OutroNumero;',
));
for (final SqlResultSet conjunto in resultado.resultSets) {
  print(conjunto.columns);
  print(conjunto.rows);
}
```

Cada SELECT produz seu conjunto. Comandos sem colunas não geram `SqlResultSet`.

## Inserção em massa

```dart
final int inseridas = await db.bulkInsert(
  'dbo.ItensCarga',
  <Map<String, dynamic>>[
    {'Codigo': 10, 'Nome': 'Ana'},
    {'Codigo': 11, 'Nome': 'Maria'},
  ],
  columns: ['Codigo', 'Nome'],
  batchSize: 1000,
);
```

Use uma tabela de carga existente com colunas e tipos compatíveis. Sem `columns`, usa as chaves da primeira linha. Cargas contendo texto usam INSERT parametrizado, com as colunas indicadas por nome.

Retorna `Future<int>`, sem `SqlResponse` ou IDs. Texto, datas, valores nulos, objetos convertidos em texto e tabelas temporárias `#` usam um INSERT parametrizado por linha. Esse caminho compartilha o codec das outras operações, pode ser mais lento e não usa `batchSize`.

FreeTDS BCP é usado apenas em cargas de valores numéricos/binários não nulos para tabelas comuns. Nesse caminho, as colunas são vinculadas por posição ordinal, e os tipos são escolhidos pela primeira linha; mantenha a ordem física da tabela e tipos consistentes. `batchSize` controla os lotes BCP. Lista vazia retorna zero após a verificação de conexão. Linhas/lotes anteriores podem já ter sido gravados se uma etapa posterior falhar; não presuma atomicidade da carga.

## Transações

```dart
await db.beginTransaction();
try {
  conferir(await db.writeDataWithParams(
    'UPDATE dbo.Usuarios SET Nome = @nome WHERE Id = @id',
    {'nome': 'Ana', 'id': 1},
  ));
  conferir(await db.writeDataWithParams(
    'UPDATE dbo.Usuarios SET Nome = @nome WHERE Id = @id',
    {'nome': 'Maria', 'id': 2},
  ));
  await db.commit();
} catch (_) {
  await db.rollback();
  rethrow;
}
```

`beginTransaction`, `commit` e `rollback` retornam `Future<void>`. Agrupam operações na mesma conexão. A instância é compartilhada: não intercale operações de outros consumidores durante a transação. Esses helpers descartam o `SqlResponse` interno; para conferir também `response.error` dos comandos de controle, use `conferir(await db.writeData('BEGIN TRAN'))`, e o equivalente para `COMMIT`/`ROLLBACK`. Um rollback também pode falhar se a conexão cair.

## Erros e encerramento

```dart
try {
  final SqlResponse resultado = conferir(await db.getData('SELECT 1 AS Ok'));
  print(resultado.resultSets.first.rows);
} on SQLException catch (e) {
  print(e.message);
} on FormatException catch (e) {
  print(e); // por exemplo: resultado com bytes inválidos em UTF-8
} on StateError catch (e) {
  print(e); // por exemplo: operação antes de conectar
} finally {
  final bool encerrado = await db.disconnect();
  print(encerrado);
}
```

Outras exceções podem ocorrer, como falha ao carregar a biblioteca nativa ou codificar um parâmetro. `disconnect()` limpa o cliente e as credenciais salvas, inclusive quando não havia conexão. O retorno não garante que todo erro nativo de fechamento tenha sido propagado, pois a camada interna captura erros.

`db.isConnected` consulta o estado local, sem testar a rede. A biblioteca tenta reconectar quando o cliente está marcado como desconectado e ainda há parâmetros salvos; não garante recuperação automática de toda queda. Após `disconnect()`, chame `connect()` novamente.

Os callbacks do FreeTDS armazenam diagnósticos e também os enviam ao logger quando habilitado. `SQLException` na inicialização/login independe do logger. A captura é feita durante cada chamada nativa, inclusive quando a conexão falha antes de existir um identificador válido para o chamador.

## Validar os exemplos e codecs

Testes locais, sem SQL Server:

```sh
dart test test/test_utils_test.dart test/freetds_text_test.dart test/freetds_legacy_decoder_test.dart
flutter analyze --no-pub test
```

`freetds_legacy_decoder_test.dart` reproduz defeitos do decoder antigo apenas nos testes; ele não é usado em produção.

Para validar SQL, RPC, procedure e bulk de texto em homologação, defina no ambiente do processo `MSSQL_IP`, `MSSQL_USER` e `MSSQL_PASSWORD`; opcionalmente, `MSSQL_PORT` (padrão `1433`) e `MSSQL_DB` (padrão `tempdb`):

```sh
dart test test/freetds_text_integration_test.dart
```

Esse teste usa tabela e procedure temporárias de sessão, compara texto Unicode, texto longo e NUL intencional sem limpeza e encerra a conexão ao terminar. Sem as variáveis obrigatórias, é ignorado. O pacote e esse teste não carregam `.env` automaticamente: carregue suas chaves no ambiente antes de executar. Se usar `IP`, `PORT`, `DB`, `LOGIN` e `PWD` no arquivo, mapeie-as respectivamente para as cinco variáveis `MSSQL_*` acima. Não versione o arquivo nem exponha os valores nos logs.

Os helpers `runWithClientAndTempDb` e `TempDbHarness`, além da suíte `mssql_connection_api_test.dart`, criam e removem bancos. Exigem `RUN_DB_TESTS=1`, `MSSQL_SERVER=host:porta`, `MSSQL_USER` e `MSSQL_PASSWORD` (ou `MSSQL_PASS`). Use somente servidor destinado a testes. Os testes negativos de autenticação também exigem `RUN_DB_TESTS=1`, usam `TestDbConfig` (`MSSQL_IP`, `MSSQL_PORT`, `MSSQL_DB`, `MSSQL_USER`, `MSSQL_PASSWORD`) e fazem tentativas de login inválido; considere a política de bloqueio de contas antes de executá-los.

Os helpers de resultados dos testes recebem `SqlResponse`, não JSON: `parseRows` transforma um único conjunto em mapas por coluna; `affectedCount` lê `totalAffectedRows`. Ambos verificam `response.error`. São utilitários da suíte, não métodos da API pública. Preserve a execução serial configurada em `dart_test.yaml`; testes de desempenho não fazem parte da verificação padrão.
