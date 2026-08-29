# Sincronizacao semanal do Elevate 4D Hub

Este repositorio verifica o site original toda segunda-feira, as 09:17 no horario de Brasilia.

Quando encontra mudancas, a automacao:

1. baixa novamente todas as paginas e arquivos internos acessiveis;
2. compara o resultado com a copia atual;
3. cria ou atualiza o Pull Request `automation/site-sync`;
4. envia o link do Pull Request pelo Telegram, quando o bot estiver configurado;
5. aguarda aprovacao humana. Nada e publicado automaticamente na branch `main`.

Depois que o Pull Request for revisado e incorporado com **Merge pull request**, o GitHub Pages publica a nova versao.

## Permissoes obrigatorias no GitHub

Em **Settings -> Actions -> General -> Workflow permissions**:

- selecione **Read and write permissions**;
- marque **Allow GitHub Actions to create and approve pull requests**;
- clique em **Save**.

## Segredos do Telegram

A notificacao usa a API oficial de bots do Telegram.

1. No Telegram, abra uma conversa com `@BotFather`.
2. Envie `/newbot` e siga as instrucoes para criar o bot.
3. Copie o token fornecido pelo BotFather.
4. Abra uma conversa com o bot criado e envie `/start`.
5. Obtenha o `chat_id` dessa conversa usando o metodo `getUpdates` da Bot API.

Em **Settings -> Secrets and variables -> Actions -> New repository secret**, cadastre:

- `TELEGRAM_BOT_TOKEN`: token secreto fornecido pelo BotFather;
- `TELEGRAM_CHAT_ID`: identificador numerico da conversa que recebera o aviso.

Os valores ficam protegidos pelo GitHub e nunca devem ser colocados diretamente nos arquivos deste repositorio publico.

## Teste manual

Abra **Actions -> Verificar atualizacoes do site original -> Run workflow**. Se nao houver mudanca, a execucao termina sem criar Pull Request. Se o Telegram ainda nao estiver configurado, a verificacao e o Pull Request continuam funcionando normalmente.
