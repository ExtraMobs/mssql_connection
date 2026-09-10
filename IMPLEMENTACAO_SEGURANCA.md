# Implementação das correções

Escopo atualizado pelo usuário: somente Windows permanece ativo. Os arquivos de outras plataformas foram movidos para `todo/`; [TODO.md](TODO.md) preserva os resultados e as pendências. A tabela abaixo registra também o histórico desse trabalho, sem declarar suporte ativo fora do Windows. A integração SQL Windows ainda exige o certificado confiável do servidor de testes.

Estado de trabalho, 2026-09-09. A tarefa ainda não está concluída. O relatório original em `AUDITORIA_SEGURANCA_COMPATIBILIDADE.md` registra o diagnóstico anterior às alterações.

| Item | Implementação atual | Prova / pendência |
|---|---|---|
| TLS obrigatório e confiança | Configuração explícita de CA e hostname, `require`, TLS mínimo 1.2 no FreeTDS; bibliotecas antigas rejeitadas | DLL Windows rejeitou servidor sem TLS antes do login e certificado autoassinado do servidor de testes; integração aguarda PEM confiável/hostname |
| Loader | Caminhos absolutos de bundle; Windows usa busca restrita por carregamento; desenvolvimento requer diretório explícito | Teste de carregamento da DLL passou e aplicativo Windows release compilou; inspeção de dependências confirmou bundle sem DLLs OpenSSL antigas |
| Identificadores/parametrização | Parser de nomes SQL delimitados, validação de nomes de parâmetro e duplicatas | Regressões locais passaram |
| Credenciais | Literais removidos da ferramenta e exemplos; `.env*` ignorado | Rotação depende do responsável pelo servidor; configuração de teste foi carregada, mas TLS falhou antes do login e das consultas |
| OpenSSL | Fonte LTS 3.5.8 e SHA-256 fixados; scripts de build estático | DLL Windows x64 recompilada e carregada nos testes nativos; demais plataformas adiadas em TODO.md |
| Money/decimal | Layout corrigido, resultados decimais exatos em strings | Regressão de MONEY passou; round-trip SQL pendente |
| Vazio/NULL | Ponteiro nulo distinto de zero bytes; extensão DBRPCEMPTY no FreeTDS | Regressões Dart passaram; integração nativa/SQL pendente |
| Callbacks/ABI | INT_CANCEL; assinatura de tdsdbopen/dbclose; inicialização nativa com proprietário único | Teste nativo Windows de ABI, setters e erro sem encerramento passou |
| Transações/ciclo de vida | Reserva por callback, fila de operações, invalidação e fechamento em falhas, liberação de LOGINREC | Regressões de liberação/falhas passaram; concorrência de transações com SQL pendente |
| BCP | Checagem da ordem completa da tabela e tipos de todas as linhas; fallback parametrizado inclusive para `[#Tabela]` | Regressões locais de promoção para bigint, reordenação e temporárias delimitadas passaram; SQL real pendente |
| Erros/limites | Falhas parciais lançam exceção; timeout nativo e limites de resultado | Regressão de erro de leitura passou; teste de timeout real pendente |
| Datas | RPC datetimeoffset binário; leitura independente de locale com até sete casas | Regressão de decoder passou; matriz DATEFORMAT/procedure preparada, ainda não executada |
| Windows | CMake/header alinhados ao nome do pacote; OpenSSL 3.5.8 estático incorporado à DLL | Biblioteca e aplicativo release compilados; arquitetura x64, demais arquiteturas não validadas |
| Android | Arquivado em todo/android e todo/example/android | APK e AAB compilaram; ELF e alinhamento do APK verificados. Execução em dispositivo e verificação de alinhamento do AAB pendentes; detalhes em TODO.md |
| iOS/macOS/Linux | Arquivados em todo/ com scripts e workflow | Sem compilação/execução local; retomada documentada em TODO.md |
| Exemplo/documentação | SqlResponse exibido corretamente, transação migrada, CA/hostname configuráveis | Análise e build Windows release passaram após restringir o manifesto ao Windows |

Validação já executada nesta implementação: 21 testes em `test/freetds_text_test.dart` passaram, incluindo rejeição de overflow nos timeouts, falha de conversão decimal, BCP e vazio/NULL; análise Flutter sem problemas após as últimas alterações Dart. Esses testes usam DB-Lib simulado e não comprovam o ABI nem uma conexão real.

O usuário confirmou que o destino do `.env` é um ambiente de testes. A tentativa de integração foi rejeitada durante TLS por certificado autoassinado, antes das consultas. Foi solicitado o PEM confiável e hostname; não foi desativada a validação. Os novos testes de integração usam objetos temporários de sessão; a ferramenta manual continua exigindo cuidado por criar/remover banco.

Verificação nativa Windows: os três testes de `test/native_library_test.dart` passaram, incluindo rejeição de substituição dos callbacks por outro isolate. `flutter build windows --release` no exemplo passou após arquivar as demais plataformas; o bundle contém `sybdb.dll`, `sql_server_wrapper_plugin.dll` e `flutter_windows.dll`, sem dependência nas DLLs OpenSSL 1.1.1. DLLs antigas, import libraries e executável de teste obsoletos foram removidos após conferir que não tinham alterações locais. O exemplo oferece CA/hostname e não imprime mais a senha digitada.

Mudanças de contrato necessárias: transações manuais compartilhadas foram substituídas por `transaction`; MONEY/DECIMAL são strings exatas; DateTime usa datetimeoffset; erros nativos invalidam a sessão e exigem reconexão explícita. As alterações locais preexistentes em análise/arquivos gerados foram preservadas.
