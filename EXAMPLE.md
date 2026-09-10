# Exemplos de uso

API atual do pacote `sql_server_wrapper` (`0.0.1`). Os trechos Dart com `await` devem ficar dentro de uma função `async`. Eles usam a conexão `db` abaixo; tabelas e procedures devem existir no seu banco.

O pacote ativo registra somente Windows x64. As outras plataformas estão arquivadas em `todo/`, com progresso em [TODO.md](TODO.md). A integração SQL Windows passou com `trustServerCertificate: true`; a configuração manual de CA/hostname ainda não foi testada de ponta a ponta com certificado confiável. Consulte [IMPLEMENTACAO_SEGURANCA.md](IMPLEMENTACAO_SEGURANCA.md).

## Conectar

```dart
import 'package:sql_server_wrapper/mssql_connection.dart';
import 'dart:io';

final MssqlConnection db = MssqlConnection(); // sessão independente
final env = Platform.environment; // configure no ambiente; não embuta senhas

try {
  final bool conectado = await db.connect(
    ip: env['MSSQL_IP']!,
    port: env['MSSQL_PORT'] ?? '1433', // String
    databaseName: env['MSSQL_DB'] ?? 'tempdb',
    username: env['MSSQL_USER']!,
    password: env['MSSQL_PASSWORD']!,
    timeoutInSeconds: 15, // int; timeout de conexão/login
    queryTimeoutSeconds: 30, // timeout nativo das consultas
    caFile: env['MSSQL_CA_FILE'] ?? 'system',
    trustServerCertificate: false, // true aceita autoassinados; mantém TLS
    certificateHostname: env['MSSQL_CERTIFICATE_HOSTNAME'],
    maxResultRows: 100000,
    maxResultBytes: 64 * 1024 * 1024,
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

TLS 1.2 ou superior é obrigatório. Por padrão, `trustServerCertificate: false` valida cadeia e hostname. Com `true`, aceita certificados autoassinados e ignora essas duas verificações, mantendo a criptografia. Nesse modo não é necessário fornecer CA/hostname; use os valores padrão desses argumentos.

**Configuração TLS manual (`caFile`/`certificateHostname`): não testada de ponta a ponta com certificado confiável.** `caFile` aceita PEM absoluto ou `system` (confiança do OpenSSL, não necessariamente do Windows). Ao conectar por IP, `certificateHostname` informa o nome esperado no certificado. O pacote não carrega `.env` por conta própria. A integração Windows com `MSSQL_TRUST_SERVER_CERTIFICATE=true` passou no servidor de testes.

`MssqlConnection.getInstance()` continua disponível para uma sessão compartilhada. As operações são serializadas; chamadas FFI bloqueiam o isolate proprietário. Não use `Isolate.run` para distribuir chamadas: a inicialização nativa rejeita outro proprietário dos callbacks.

No aplicativo Flutter Windows, a DLL é carregada do bundle. Para execução Dart independente, configure `NativeLoader.libraryDirectory` com o caminho absoluto de `windows/Libraries/bin` antes da primeira conexão. A busca não usa o diretório de trabalho nem `PATH`; a DLL precisa conter as extensões atuais de segurança.

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
| `transaction<T>((tx) async { ... })` | `Future<T>` | Valor retornado pelo callback após commit |
| `disconnect()` | `Future<bool>` | Resultado do encerramento pela API |
| `isConnected` | `bool` | Propriedade síncrona; não usa `await` |

`getData` e `writeData` chamam a mesma execução internamente. Os nomes expressam a intenção; não restringem o SQL a leitura ou escrita. O mesmo vale para as versões `WithParams`.

## Estrutura de `SqlResponse`

| Campo | Tipo | Conteúdo |
|---|---|---|
| `resultSets` | `List<SqlResultSet>` | Conjuntos retornados com colunas |
| `totalAffectedRows` | `int` | Soma das contagens reportadas pelo FreeTDS |
| `error` | `String?` | Campo mantido no modelo; o cliente atual lança exceções em falhas de coleta |
| `resultSets[i].columns` | `List<String>` | Nomes das colunas, em ordem |
| `resultSets[i].rows` | `List<List<dynamic>>` | Linhas; cada posição corresponde a uma coluna |

O retorno é um objeto Dart, sem necessidade de `jsonDecode`. As células são `dynamic`, não modelos tipados nem mapas por nome de coluna. Para contar linhas de um SELECT, use `rows.length`; `totalAffectedRows` soma somente contagens positivas do driver e depende dos comandos e de `SET NOCOUNT`.

Falhas nativas e de coleta lançam exceções e invalidam a sessão; não retornam resultados parciais como sucesso. O helper abaixo é defensivo para objetos que preencham o campo opcional `error`; ele não substitui o tratamento de exceções:

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
| `double` finito | `float`; NaN e infinito são rejeitados |
| `bool` | `bit` |
| `String` | `nvarchar(max)`; buffer UTF-8 e parâmetro RPC Unicode |
| `DateTime` | `datetimeoffset(7)` binário, preservando instante, offset e microssegundos |
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

`DateTime` é codificado com instante UTC e offset original, dentro do intervalo suportado pelo SQL Server. A conversão para `datetime`, `datetime2` e outros destinos deve ser validada quanto a precisão, fuso e `DATEFORMAT`. Outros objetos passam por `toString()`; prefira os tipos acima. Nomes de parâmetros são validados e duplicatas como `id`/`@ID` são rejeitadas; `WithParams` aceita até 2098 parâmetros do usuário.

## Tipos das células retornadas

| Tipo SQL comum | Valor Dart atual |
|---|---|
| Inteiros | `int` |
| `bit` | `bool` |
| `real`, `float` | `double` |
| `money`, `smallmoney`, `decimal`, `numeric` | `String` decimal exata, sem conversão para `double` |
| Texto | `String` |
| `datetime`, `smalldatetime` | `String` em formato ISO, não `DateTime` |
| `date`, `time`, `datetime2`, `datetimeoffset` | `String`; tipos modernos preservam até sete casas e `datetimeoffset` inclui offset |
| Binários (`binary`, `varbinary`, `image`) | `String` Base64, não `Uint8List` |
| `NULL` | `null` |

Texto vazio retorna `''`; binário vazio retorna `''` em Base64; SQL NULL retorna `null`. Essa distinção também é preservada nos parâmetros RPC. Conversão decimal que falha lança `FormatException`, em vez de retornar bytes. Outros tipos podem usar conversões do FreeTDS e fallbacks; confira o tipo antes de fazer casts.

```dart
import 'dart:convert';
import 'dart:typed_data';

// Se a célula binária não for nula:
final Uint8List bytes = base64Decode(valorBase64);
// Se a célula contiver uma data ISO válida:
final DateTime data = DateTime.parse(valorData);
```

`valorBase64` e `valorData` representam strings obtidas das células correspondentes.

Datas SQL sem offset são civis: `DateTime.parse` interpreta uma string sem offset no fuso local. O Dart preserva microssegundos, portanto converter uma string com sete casas para `DateTime` perde a precisão adicional. Preserve a string quando precisar da representação exata.

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

FreeTDS BCP é usado apenas em cargas numéricas/binárias não nulas e homogêneas para tabelas comuns. O cliente verifica todas as linhas, promove inteiros para 64 bits quando necessário e compara as colunas com os metadados da tabela. Ordem diferente ou seleção parcial de colunas usa INSERT parametrizado por nome. Binário vazio também usa esse fallback. `batchSize` controla somente os lotes BCP. Lista vazia retorna zero após validar conexão, nome da tabela e tamanho de lote. Linhas/lotes anteriores podem permanecer gravados após uma falha; envolva `bulkInsert` em `transaction` quando precisar de atomicidade.

## Transações

```dart
await db.transaction((tx) async {
  conferir(await tx.writeDataWithParams(
    'UPDATE dbo.Usuarios SET Nome = @nome WHERE Id = @id',
    {'nome': 'Ana', 'id': 1},
  ));
  conferir(await tx.writeDataWithParams(
    'UPDATE dbo.Usuarios SET Nome = @nome WHERE Id = @id',
    {'nome': 'Maria', 'id': 2},
  ));
});
```

`transaction` reserva a sessão durante todo o callback, inclusive seus `await`. Operações externas aguardam; sucesso faz commit e uma exceção provoca rollback se a sessão ainda estiver conectada. Falha nativa fecha/invalida a sessão. Aguarde todas as operações dentro do callback e deixe os erros propagarem. Transações aninhadas, substituição da sessão dentro da transação e operações de callbacks atrasados após seu término são rejeitadas.

`beginTransaction`, `commit` e `rollback` estão obsoletos e lançam `UnsupportedError`. Migre para o callback; comandos manuais `BEGIN TRAN` enviados por SQL livre não adquirem essa reserva.

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

Outras exceções podem ocorrer, como `ArgumentError` por entrada inválida ou falha ao carregar a DLL. Limites de linhas/bytes excedidos lançam erro e invalidam a sessão. `disconnect()` remove e fecha o cliente; não há parâmetros salvos para reconexão automática.

`db.isConnected` consulta o estado local, sem testar a rede. Após falha nativa ou `disconnect()`, chame `connect()` explicitamente. Operações sem sessão conectada lançam `StateError`; nenhuma transação é reconectada ou repetida automaticamente.

Os callbacks do FreeTDS armazenam diagnósticos e também os enviam ao logger quando habilitado. `SQLException` na inicialização/login independe do logger. A captura é feita durante cada chamada nativa, inclusive quando a conexão falha antes de existir um identificador válido para o chamador.

## Validar os exemplos e codecs

Testes locais, sem SQL Server:

```sh
dart test test/freetds_text_test.dart
dart test test/native_library_test.dart
flutter analyze --no-pub
```

O primeiro teste usa DB-Lib simulado. O segundo carrega a DLL Windows e valida ABI, callbacks e rejeição de servidor sem TLS, sem acessar SQL Server. Execute-os em invocações separadas por causa do proprietário dos callbacks. Testes históricos do decoder antigo não provam o comportamento atual.

Para validar SQL, RPC, procedures, tipos e transações em homologação, defina `MSSQL_IP`, `MSSQL_USER` e `MSSQL_PASSWORD`; opcionais: `MSSQL_PORT` (1433), `MSSQL_DB` (tempdb), `MSSQL_CA_FILE` e `MSSQL_CERTIFICATE_HOSTNAME`. Em Dart independente no Windows, defina também `MSSQL_NATIVE_DIR` com o caminho absoluto de `windows/Libraries/bin`:

Para optar explicitamente por confiar no certificado apresentado, defina `MSSQL_TRUST_SERVER_CERTIFICATE=true`. Sem essa variável, a validação do certificado permanece ativada.

```sh
dart test test/freetds_text_integration_test.dart
```

Esse teste usa tabela e procedure temporárias de sessão, compara texto Unicode, texto longo e NUL intencional sem limpeza e encerra a conexão ao terminar. Sem as variáveis obrigatórias, é ignorado. O pacote e esse teste não carregam `.env` automaticamente: carregue suas chaves no ambiente antes de executar. Se usar `IP`, `PORT`, `DB`, `LOGIN` e `PWD` no arquivo, mapeie-as respectivamente para as cinco variáveis `MSSQL_*` acima. Não versione o arquivo nem exponha os valores nos logs.

Os helpers `runWithClientAndTempDb` e `TempDbHarness`, além da suíte `mssql_connection_api_test.dart`, criam e removem bancos. Exigem `RUN_DB_TESTS=1`, `MSSQL_SERVER=host:porta`, `MSSQL_USER` e `MSSQL_PASSWORD` (ou `MSSQL_PASS`). Use somente servidor destinado a testes. Os testes negativos de autenticação também exigem `RUN_DB_TESTS=1`, usam `TestDbConfig` (`MSSQL_IP`, `MSSQL_PORT`, `MSSQL_DB`, `MSSQL_USER`, `MSSQL_PASSWORD`) e fazem tentativas de login inválido; considere a política de bloqueio de contas antes de executá-los.

Os helpers de resultados dos testes recebem `SqlResponse`, não JSON: `parseRows` transforma um único conjunto em mapas por coluna; `affectedCount` lê `totalAffectedRows`. Ambos verificam `response.error`. São utilitários da suíte, não métodos da API pública. Preserve a execução serial configurada em `dart_test.yaml`; testes de desempenho não fazem parte da verificação padrão.
