# sql_server_wrapper

Cliente Flutter/Dart para SQL Server via FFI e FreeTDS 1.5.4 vendorizado. O nome e a versão do pacote são os de `pubspec.yaml` (`sql_server_wrapper`, `0.0.1`). Não há implementação web.

## Instalação e plataformas

Para usar este checkout:

```yaml
dependencies:
  sql_server_wrapper:
    path: ../mssql_connection
```

```dart
import 'package:sql_server_wrapper/sql_server_wrapper.dart';
```

O pacote ativo registra somente **Windows x64**. Fontes, binários e scripts das outras plataformas estão arquivados em `todo/`; consulte [TODO.md](TODO.md) para progresso e pendências. Windows ARM64 não foi validado. Consulte `IMPLEMENTACAO_SEGURANCA.md` para a validação SQL ainda pendente; compilar o exemplo não prova todos os comportamentos do driver. Web precisa de um backend/API.

As instruções das plataformas adiadas devem ser retomadas junto dos arquivos em `todo/`, antes de voltar a registrá-las no manifesto.

## Conexão segura

TLS 1.2 ou superior, criptografia obrigatória e validação do certificado são parte da conexão; não há opção `trustServerCertificate` nem fallback para texto claro. Use uma conta com os privilégios necessários ao aplicativo, sem embutir credenciais administrativas no código.

```dart
final connection = MssqlConnection(); // sessão independente
final connected = await connection.connect(
  ip: serverHost,
  port: '1433',
  databaseName: database,
  username: user,
  password: password,
  caFile: absoluteCaPemPath,
  queryTimeoutSeconds: 30,
);
```

`caFile` aceita um caminho absoluto para um PEM de CAs confiáveis, ou `system` (padrão). O armazenamento de confiança do OpenSSL não é necessariamente o armazenamento do sistema operacional: no Android/iOS, distribua um PEM de CAs e forneça seu caminho absoluto. Não use o certificado apresentado por um servidor desconhecido como CA automaticamente. O hostname do certificado deve corresponder ao host informado; `certificateHostname` permite usar o nome DNS esperado ao conectar a um IP explícito.

O cliente exige as extensões deste FreeTDS vendorizado. Uma DLL antiga ou uma biblioteca FreeTDS instalada aleatoriamente no sistema é rejeitada. O loader usa caminhos do aplicativo instalado, nunca o diretório de trabalho ou `PATH`. Para desenvolvimento com Dart fora de um app empacotado, configure explicitamente antes do primeiro uso:

```dart
NativeLoader.libraryDirectory = absoluteTrustedBuildDirectory;
```

As operações são serializadas por sessão. Use um único isolate proprietário para todas as chamadas DB-Lib no processo: os callbacks nativos são globais e a inicialização rejeita outro proprietário. `async` não torna a chamada FFI não bloqueante; se necessário, mantenha o cliente inteiro em um isolate dedicado e troque mensagens com a UI.

## Consultas, resultados e parâmetros

```dart
final response = await connection.getDataWithParams(
  'SELECT id, nome FROM dbo.Pessoas WHERE id = @id',
  {'id': 42},
);
for (final result in response.resultSets) {
  print(result.columns);
  for (final row in result.rows) {
    print(row);
  }
}
print(response.totalAffectedRows);
```

`getData`, `writeData`, variantes `WithParams` e `executeProcedure` retornam `SqlResponse`, não JSON. Falhas nativas/SQL/decodificação são exceções e invalidam a sessão; não há retorno parcial apresentado como sucesso. Reconecte explicitamente após uma falha. Não há reexecução automática de escrita nem reconexão dentro de transação.

Valores de parâmetros usam RPC; não concatene entrada externa no SQL. Nomes de parâmetros são validados e duplicatas como `p`/`@P` são rejeitadas. Nomes qualificados de tabela/procedure aceitam identificadores regulares ou delimitados com colchetes, incluindo `dbo.[Nome com espaço]` e `#Temporaria`. Valores vazios e `NULL` são distintos. C strings de SQL/identificadores/credenciais rejeitam NUL; valores parametrizados preservam NUL.

| Tipo | Contrato |
|---|---|
| Texto | UTF-8 no cliente; Unicode no RPC; resultados inválidos em UTF-8 lançam `FormatException`. |
| `int`, `double`, `bool` | Tipos binários correspondentes; NaN e infinito são rejeitados. |
| `money`, `smallmoney`, `decimal`, `numeric` lidos | Strings decimais exatas. Não converter para `double` para cálculos financeiros exatos. |
| `DateTime` enviado | `datetimeoffset(7)` binário, preservando o instante e o offset do objeto, com precisão de microssegundos do Dart. Conversões SQL para tipos sem offset seguem a semântica do SQL Server. |
| Datas lidas | Strings ISO, preservando até sete casas dos tipos modernos; `datetimeoffset` inclui offset. Datas sem fuso não recebem um fuso inventado. |
| `Uint8List` enviado | `varbinary`; binários lidos continuam em Base64. Vazio é `''`; SQL NULL é `null`. |

`queryTimeoutSeconds` configura timeout nativo de consulta. `maxResultRows` (100.000 por padrão) e `maxResultBytes` (64 MiB de payload por padrão) limitam resultados acumulados; ultrapassá-los lança exceção e fecha a sessão. Esses limites não são streaming nem limitam toda memória interna do FreeTDS. Paginação SQL continua apropriada para grandes volumes.

## Transações e bulk insert

```dart
await connection.transaction((tx) async {
  await tx.writeDataWithParams(
    'UPDATE dbo.Contas SET saldo = saldo - @valor WHERE id = @id',
    {'valor': 10, 'id': 1},
  );
  await tx.writeDataWithParams(
    'UPDATE dbo.Contas SET saldo = saldo + @valor WHERE id = @id',
    {'valor': 10, 'id': 2},
  );
});
```

A conexão fica reservada durante todo o callback, inclusive seus `await`. Sucesso confirma; exceção desfaz. Outras operações aguardam. Callbacks usados após o encerramento e transações aninhadas são rejeitados. Aguarde todas as operações iniciadas no callback.

Os antigos `beginTransaction`, `commit` e `rollback` da conexão compartilhada agora rejeitam uso: sem um escopo proprietário, não conseguem impedir que outro consumidor participe da transação. Migre para o callback acima. `getInstance()` permanece disponível para compatibilidade, mas sessões independentes podem ser criadas com `MssqlConnection()`.

`bulkInsert(table, rows, columns: ..., batchSize: ...)` usa BCP somente quando as colunas correspondem à ordem completa da tabela e os valores são numéricos/binários não nulos e compatíveis. Inteiros são promovidos segundo todas as linhas. Outros casos usam INSERT parametrizado por linha, com colunas explícitas; nesse caminho `batchSize` não agrupa INSERTs. Sem transação externa, linhas/batches já confirmados permanecem gravados se uma linha posterior falhar. Use `transaction` quando a carga precisa ser atômica.

## Bibliotecas nativas e validação

`scripts/fetch-openssl.py` fixa OpenSSL LTS 3.5.8 e verifica SHA-256. `scripts/build-openssl.ps1` e `scripts/build-windows.ps1` recompilam o runtime Windows com TLS. Scripts das demais plataformas estão em `todo/scripts/`. A versão do OpenSSL deve ser atualizada junto do checksum após revisão de novos avisos de segurança. Não substitua só uma DLL por outra versão ABI incompatível.

O workflow `.github/workflows/freetds-multi.yml` prepara os builds e testes por plataforma. Artefatos de CI precisam ser incorporados e validados antes de publicar suporte a uma plataforma; não trate binários históricos como resultado do novo build.

```sh
flutter analyze
dart test test/freetds_text_test.dart
dart test test/native_library_test.dart
```

Execute o teste de biblioteca nativa em uma invocação separada, pois os callbacks têm proprietário por isolate. Para integração, configure explicitamente `MSSQL_IP`, `MSSQL_USER`, `MSSQL_PASSWORD` e, conforme necessário, `MSSQL_PORT`, `MSSQL_DB`, `MSSQL_CA_FILE`, `MSSQL_CERTIFICATE_HOSTNAME`, `MSSQL_NATIVE_DIR`:

```sh
dart test test/freetds_text_integration_test.dart
```

Esse teste usa objetos temporários de sessão e valida SQL/RPC/procedures/bulk, tipos, transações e TLS. Sem configuração, é ignorado. Outros helpers e `tool/integration_db_lifecycle.dart` criam/removem bancos: use somente servidor destinado a testes. Não inclua `.env` ou credenciais no Git. A configuração `dart_test.yaml` mantém testes seriais na VM; isso não substitui a propriedade correta dos callbacks.

Este projeto deriva de `mssql_connection`; consulte `LICENSE` e as licenças FreeTDS/OpenSSL distribuídas com suas fontes.
