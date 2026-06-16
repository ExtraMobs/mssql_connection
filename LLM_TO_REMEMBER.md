# LLM_TO_REMEMBER — FreeTDS RPC Parameter Encoding

> **Contexto:** Este documento registra o raciocínio e os fatos técnicos descobertos durante a correção de erros no protocolo TDS ao enviar parâmetros via `dbrpcparam` (FreeTDS DB-Lib). Serve como referência para futuras manutenções ou assistentes de IA.

---

## Problema Original

Ao chamar `sp_executesql` (via `executeParams`) ou uma Stored Procedure diretamente (via `executeProcedure`), os seguintes erros eram lançados pelo SQL Server:

```
[msgno=8016] Parameter "@stmt": Data type 0xE7 has an invalid data length or metadata length.
[msgno=102]  Incorrect syntax near 'd'.
[msgno=8114] Error converting data type nvarchar to datetime.
```

---

## Causa Raiz

### 1. `datalen` incorreto em `dbrpcparam`

A assinatura de `dbrpcparam` no FreeTDS é:

```c
int dbrpcparam(DBPROCESS*, const char* name, BYTE status,
               int type, int maxlen, int datalen, BYTE* value);
```

**`datalen` deve ser sempre o número exato de bytes do buffer (`buf.length`)**, independentemente do tipo (`SYBVARCHAR` ou `SYBNVARCHAR`).

O código original tinha operadores de bitwise shift incorretos:

| Localização | Operação errada | Efeito |
|---|---|---|
| `executeParams` — `@stmt` e `@params` | `buf.length >> 1` | Dividia o tamanho por 2, truncando a string da query no meio |
| `executeParams` — user params | `buf.length << 1` | Dobrava o tamanho, corrompendo os metadados do pacote |
| `executeProcedure` — todos os params | `buf.length << 1` | Mesmo problema |

**Correção:** Remover todos os shifts. Passar sempre `rpcVal.buf.length` diretamente.

```dart
// ERRADO
(rpcVal.type == SYBNVARCHAR) ? (rpcVal.buf.length << 1) : rpcVal.buf.length

// CORRETO
rpcVal.buf.length
```

> **Por quê o shift parecia fazer sentido?**  
> NVARCHAR usa UTF-16LE: cada caractere ocupa 2 bytes. Alguém raciocinou que o FreeTDS esperaria a contagem de *caracteres* (não bytes) para NVARCHAR, então tentou dividir por 2 com `>> 1`. Na realidade, o FreeTDS trata `datalen` como bytes em todos os tipos — é o próprio protocolo TDS que sabe interpretar o tipo correto de acordo com o campo `type`.

---

### 2. Separador `T` no formato de `DateTime`

Ao passar `DateTime` como `SYBVARCHAR` para uma Stored Procedure que espera `datetime`, o SQL Server faz conversão implícita `varchar → datetime`.

A função `_formatDateTimeForSql` gerava o formato ISO8601 com a letra `T`:

```
2025-08-28T12:00:00
```

O SQL Server **rejeita este formato** via conversão implícita em algumas configurações de `DATEFORMAT`/locale (especialmente `DATEFORMAT = dmy`). O formato correto e universalmente aceito é:

```
2025-08-28 12:00:00
```

**Correção:** Substituir o separador `T` por espaço em `_formatDateTimeForSql`.

```dart
// ERRADO
'${...}-${...}-${...}T${...}:${...}:${...}'

// CORRETO
'${...}-${...}-${...} ${...}:${...}:${...}'
```

> **Por quê não usar `.toIso8601String()` do Dart?**  
> O método `DateTime.toIso8601String()` pode emitir frações de segundo com alta precisão (ex: `2025-08-28T12:00:00.000000`). O tipo `DATETIME` do SQL Server só aceita até 3 casas decimais de milissegundo. Além disso, o `T` é problemático dependendo da configuração do servidor. Por isso, a função manual com segundos inteiros e espaço como separador é a opção mais robusta.

---

### 3. `_inferSqlType` para `DateTime`

Em `executeParams` (via `sp_executesql`), o tipo declarado na string `@params` deve ser coerente com o tipo TDS enviado na rede.

- `_encodeForRpc` para `DateTime` → retorna `SYBVARCHAR` (UTF-8, ASCII)
- `_inferSqlType` para `DateTime` → deve retornar `'varchar(50)'`

Se houver divergência (ex: declarar `nvarchar(50)` mas enviar `SYBVARCHAR`), o SQL Server pode rejeitar o parâmetro ou errar na conversão.

```dart
// CORRETO — alinhado com _encodeForRpc que retorna SYBVARCHAR
if (v is DateTime) return 'varchar(50)';
```

---

## Regras para o FreeTDS DB-Lib (`dbrpcparam`)

1. **`datalen` = `buf.length` sempre** — número bruto de bytes alocados. Nunca aplicar bitwise shift.
2. **`maxlen = -1`** para parâmetros de entrada (non-OUTPUT). Significa que o driver usa `datalen` para definir o tamanho real.
3. **`type`** define como o SQL Server interpreta os bytes. `SYBVARCHAR` (0x27) = UTF-8/ASCII. `SYBNVARCHAR` (0x67) = UTF-16LE. O `datalen` em ambos os casos é o número de **bytes** do buffer, não de caracteres.
4. **`_encodeStringSmart`** decide automaticamente entre `SYBVARCHAR` e `SYBNVARCHAR` conforme o conteúdo da string (ASCII puro → VARCHAR; caracteres além de U+007F → NVARCHAR UTF-16LE).
5. **`@stmt` e `@params`** no `sp_executesql` seguem as mesmas regras. São strings comuns e seu `datalen` é o tamanho do buffer em bytes.

---

## Teste de Validação

Foi criado um integration test (`integration_test/mssql_integration_test.dart`) que roda o app Flutter completo no Windows (`-d windows`), garantindo que as DLLs nativas do FreeTDS sejam carregadas corretamente:

```bash
flutter test integration_test/mssql_integration_test.dart -d windows
```

> **Atenção:** `flutter test` sem `-d windows` roda na Dart VM pura e **não carrega plugins nativos** (DLLs). Sempre usar `-d windows` para testar este pacote.

Resultado esperado após a correção:
```
00:00 +1: Connect and run SELECT with String param      ✓
00:00 +2: Run stored procedure ... with DateTime         ✓
All tests passed!
```

---

## Arquivos Modificados

- `lib/src/mssql_client.dart`
  - `executeParams`: `datalen` para `@stmt`, `@params` e user params
  - `executeProcedure`: `datalen` para todos os params
  - `_inferSqlType`: DateTime → `'varchar(50)'`
  - `_formatDateTimeForSql`: Separador `T` → espaço, remoção do `.toUtc()`

---

## Commit

Branch: `flutter/mssql_connection_package`  
Hash: `56d2e67`  
Mensagem: `fix: adjust DateTime format for SQL Server and remove UTC conversion`
