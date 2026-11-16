# Radar privado: Fireflies e WhatsApp

O evento Fireflies V2 `meeting.transcribed` grava um job durável antes do ACK. A função `fireflies-radar` baixa a transcrição, confirma a conta da chave, salva a cópia privada, analisa com OpenAI e publica uma revisão validada. O snapshot WhatsApp usado no cruzamento conserva seu próprio corte; nenhum estado WhatsApp é alterado automaticamente.

## Componentes

- `index.ts`: entrada Supabase Edge, com autenticação HMAC no webhook e prova HMAC de curta duração no worker; publicar os quatro arquivos irmãos.
- `handler.mjs`: verificação HMAC sobre os bytes originais, ACK em até 22 segundos, falhas transitórias com 503.
- `worker.mjs`: orçamento de 120 segundos, download antes da análise, reaproveitamento da cópia salva em retries e erros sanitizados.
- `analyzer.mjs`: prompt, validação e evidências materializadas da transcrição. Não inventa data real da call, cliente ou autoria.
- Migrações em `supabase/migrations/`: `20261116_radar_fireflies_calls.sql`, `20261116_radar_fireflies_recovery.sql` e `20261116_radar_fireflies_recovery_signatures.sql`. Vault, fila com leases, histórico imutável, leitura exclusiva do proprietário e recuperação assinada de jobs a cada minuto. A terceira migração substitui o envio do bearer da versão inicial.

## Configuração privada

1. Instalar as três migrações na ordem acima após a migração WhatsApp; publicar a função com `verify_jwt=false` (o corpo faz autenticação própria).
2. Configurar administrativamente `expected_account_email` e `webhook_url` em `ac_radar_private.calls_config`. A URL termina em `/functions/v1/fireflies-radar/webhook`. Não colocar chaves no código ou Git.
3. O proprietário entra em Radar → Calls → Configuração privada do Fireflies e salva as chaves Fireflies e OpenAI. OAuth do conector Codex não fornece credenciais ao servidor. As chaves são substituídas no Vault, nunca retornadas à interface.
4. Em https://app.fireflies.ai/integrations/api/webhook, cadastrar URL e segredo de assinatura copiados da área privada. Selecionar `meeting.transcribed`; habilitar reenvio quando as notas mudarem para receber revisões. Salvar.
5. Ativar processamento no Hub e testar. O teste de conectividade do Fireflies não prova análise real: verificar uma call real, job concluído e análise privada. Não declarar integração validada antes disso.

Webhooks comuns cobrem reuniões pertencentes à conta conectada. Cobertura da equipe inteira depende do recurso Super Admin Enterprise do Fireflies. Neste projeto o usuário confirmou uma única conta de gravação; isso ainda deve ser conferido no teste real.

## Comportamento e limites

- Duplicatas são identificadas por reunião, evento e revisão (`reprocessed_at` ou zero), não pelo timestamp de entrega. Revisão antiga nunca substitui a mais nova.
- Até cinco tentativas; falhas finais ficam no painel, sem apagar a última análise válida. Nenhum erro bruto de provedor ou segredo vai para o relatório.
- A fila compartilhada do pg_net recebe apenas corpo e assinatura válida por 90 segundos. A chave de assinatura do worker nunca é enviada à fila. Repetir essa prova só pode acionar jobs já autorizados; leases e idempotência impedem dupla publicação.
- Chamadas sem cliente inequívoco ficam em revisão privada. Datas relativas sem âncora confiável permanecem literais, sem prazo inventado.
- Interface: fontes WhatsApp e Calls; tarefas, mensagens melhores e pauta de 1:1 em cada fonte. Carteira e autoria são conceitos separados. Sugestões não são enviadas automaticamente.
- Nenhuma transcrição integral ou análise de cliente pertence ao Git, deploy estático ou skill distribuível. Dados ficam no schema privado do Supabase; resumos só via RPC do proprietário.
- Até 100 calls e 20 jobs no snapshot, com aviso de limite. Transcrições acima do limite de análise (1.000 segmentos ou tamanho da requisição) exigem revisão; não são truncadas silenciosamente.
- `enabled` autoriza processamento, mas não significa que configuração externa ou teste real foram concluídos.

## Verificação

`node --test tests/fireflies-handler.test.mjs tests/fireflies-worker.test.mjs tests/fireflies-analyzer.test.mjs`

Testes adicionais locais do banco e interface usam PGlite/JSDOM com dados sintéticos. Vault e rede são simulados somente nesses testes. A verificação de produção inclui resposta 401 sem assinatura válida, acesso exclusivo do proprietário e comparação do arquivo servido pela Vercel com a versão publicada.

Referências: https://docs.fireflies.ai/graphql-api/webhooks-v2 e https://supabase.com/docs/guides/functions/schedule-functions.
