# Orientações para manutenção

Este pacote Flutter, `sql_server_wrapper`, conecta ao SQL Server usando Dart FFI e FreeTDS. A API pública fica em `lib/src/mssql_connection.dart`; a execução SQL e a codificação RPC ficam em `lib/src/mssql_client.dart`; o carregamento nativo fica em `lib/src/native_loader.dart`.

## Estado do projeto

- O `pubspec.yaml` define o nome `sql_server_wrapper`, versão `0.0.1`, Dart `^3.9.0` e Flutter `>=3.3.0`. Use o manifesto como referência para instalação e imports.
- Os pontos de entrada são `lib/mssql_connection.dart` e `lib/sql_server_wrapper.dart`. `MssqlConnection.getInstance()` fornece uma instância compartilhada. A API oferece conexão, leitura/escrita com ou sem parâmetros, procedures, transações e bulk insert.
- Leituras, escritas e procedures retornam `SqlResponse`, com `resultSets` e `totalAffectedRows`. Cada `SqlResultSet` contém `columns` e `rows` (listas de valores). O changelog e parte dos testes ainda descrevem ou esperam strings JSON; não restaure esse contrato antigo para acomodá-los.
- Falhas nativas invalidam e fecham a sessão. Não há reconexão automática nem parâmetros salvos para esse fim; o consumidor deve chamar `connect()` explicitamente.
- `transaction((tx) async { ... })` reserva a fila durante a transação inteira. Operações externas aguardam; transações aninhadas e substituição da conexão dentro do callback são rejeitadas. A API manual antiga lança `UnsupportedError`. `MssqlConnection()` permite sessões independentes; callbacks FFI continuam limitados a um isolate proprietário por processo.

## Estrutura e plataformas

- `lib/src/ffi/freetds_bindings.dart`: bindings DB-Lib e callbacks nativos; `lib/src/sql_response.dart`: resultados; `lib/src/sql_exception.dart`: exceção SQL.
- `example/`: aplicativo Flutter de demonstração; `test/`: testes de API, entradas inválidas, parâmetros, volumes e desempenho; `tool/integration_db_lifecycle.dart`: execução manual que cria e remove banco de dados.
- `third_party/freetds-1.5.4/`: fonte vendorizada; `scripts/build-*.{ps1,sh}`: scripts existentes de compilação nativa. Confira o script da plataforma antes de recompilar ou substituir binários.
- O manifesto ativo registra somente Windows. O trabalho das demais plataformas foi arquivado em `todo/` por solicitação do usuário; consulte `TODO.md`. Consulte `IMPLEMENTACAO_SEGURANCA.md` e não declare suporte validado sem testar.
- No Windows, `windows/CMakeLists.txt` empacota `windows/Libraries/bin/sybdb.dll`, com OpenSSL estático. A configuração Android está arquivada em `todo/android/`. Mudanças no loader devem respeitar o empacotamento correspondente e não restaurar busca pelo diretório de trabalho.
- TLS permanece obrigatório. `trustServerCertificate` é `false` por padrão; `true` ignora explicitamente validação de cadeia e hostname, inclusive para autoassinados. `caFile` aceita PEM absoluto ou `system`; a configuração manual de CA/hostname ainda não foi testada de ponta a ponta com certificado confiável. A integração Windows com trustServerCertificate ativado passou. Bibliotecas antigas sem as extensões de segurança são rejeitadas.

## Parâmetros RPC

- O codec do cliente é UTF-8, centralizado em `lib/src/ffi/freetds_text.dart` e configurado via `dbsetlcharset` antes de `dbopen`. Use esse módulo para SQL, nomes, parâmetros, resultados e diagnósticos.
- Ao alterar a codificação, confira `execute`, `executeParams` (`sp_executesql`), `executeProcedure` e `bulkInsert`. O codec dos dados não se aplica às APIs Windows de caminhos de DLL, que exigem UTF-16.
- Nas chamadas atuais de `dbrpcparam`, passe o tamanho do buffer em bytes (`buf.length`) como `datalen`. Não converta esse tamanho para caracteres nem aplique shifts para NVARCHAR. Shifts causaram truncamento e erros de metadados anteriormente.
- Mantenha o tipo TDS, a codificação do buffer e a declaração SQL compatíveis. Não presuma que `SYBVARCHAR` significa UTF-8: a interpretação depende da configuração de charset.
- Strings RPC usam buffers UTF-8 com tipo Unicode `SYBNTEXT` (promovido a `NVARCHAR(MAX)` pelo FreeTDS em TDS 7.2+). Não monte UTF-16 manualmente nem reintroduza Latin-1 ou detecção de codec por zeros. Resultados inválidos em UTF-8 lançam `FormatException`; só diagnósticos de callbacks aceitam substituição por U+FFFD para não lançar através de código nativo.
- C strings de SQL/nomes/credenciais rejeitam NUL para evitar truncamento. Valores parametrizados com tamanho explícito preservam NUL. Isso não corrige dados já gravados com zeros indevidos.
- Vazio usa ponteiro não nulo, tamanho zero e a extensão `DBRPCEMPTY`; NULL usa ponteiro nulo. Preserve essa distinção no Dart e no FreeTDS vendorizado.
- BCP de variáveis de programa no FreeTDS 1.5.4 pula a conversão de charset (`tds_generic_put` com `bcp7`). Cargas contendo texto, datas, objetos convertidos em texto ou valores nulos usam o INSERT parametrizado existente, assim como tabelas `#`. BCP permanece para cargas somente numéricas/binárias não nulas. O caminho RPC faz um INSERT por linha e não usa `batchSize`; pode ser mais lento.

## Datas

`DateTime` usa `SYBMSDATETIMEOFFSET` binário e declaração `datetimeoffset(7)`. O buffer contém instante UTC e offset original; preserva microssegundos do Dart. Leituras modernas preservam até sete casas; datas SQL sem offset são representadas como datas civis, sem acrescentar `Z`. Essa implementação ainda requer a matriz de integração descrita abaixo. MONEY/DECIMAL retornam strings exatas.

Ao mudar esse comportamento, valide os dois caminhos RPC com os tipos SQL envolvidos, diferentes configurações de `DATEFORMAT`, precisão e fuso horário. Não use a antiga afirmação de que o separador ISO 8601 `T` é inválido como regra de implementação.

## Validação

- Confira os testes existentes em `test/` e sua compatibilidade com a API atual antes de escolher o comando. O antigo `integration_test/mssql_integration_test.dart` não existe neste checkout.
- `test/test_utils.dart` usa `Future<SqlResponse>` e adapta resultados em mapas. A presença da suíte não significa que os testes de banco estejam passando; eles exigem configuração explícita e podem criar/remover bancos temporários.
- Use `flutter analyze` para conferir tipos e análise estática. Para testes compatíveis com a API atual, execute `flutter test test/<arquivo>.dart` com as dependências necessárias disponíveis. Não execute testes de desempenho como verificação padrão.
- Preserve `concurrency: 1` e a plataforma `vm` de `dart_test.yaml`: a configuração documenta falhas de callbacks FFI entre isolates.
- `dart test test/freetds_text_test.dart` valida os caminhos de codificação sem acessar um banco. `dart test test/freetds_text_integration_test.dart` valida SQL/RPC/procedure/bulk com objetos temporários de sessão; exige `MSSQL_IP`, `MSSQL_USER` e `MSSQL_PASSWORD` explícitos (opcionais: `MSSQL_PORT`, `MSSQL_DB`). Sem configuração, o teste é ignorado.
- Testes com FFI podem carregar bibliotecas nativas na VM, desde que elas e suas dependências estejam disponíveis; `-d windows` não é uma exigência geral de FFI.
- Para alterações de RPC, execute um teste de integração relevante com FreeTDS e SQL Server disponíveis. Se não puder executá-lo, informe a limitação; não apresente resultados históricos como validação atual.
- Antes de executar testes de banco, confira o destino e as operações: os helpers em `test/test_utils.dart` criam e removem bancos temporários. Use um servidor destinado a testes.
- Os testes usam configurações diferentes (`MSSQL_SERVER` ou `MSSQL_IP`/`MSSQL_PORT`, entre outras). Confira o arquivo selecionado e forneça credenciais de teste explicitamente, além de `MSSQL_CA_FILE`/`MSSQL_CERTIFICATE_HOSTNAME` quando necessários. Não copie credenciais para documentação, logs ou novos testes.
