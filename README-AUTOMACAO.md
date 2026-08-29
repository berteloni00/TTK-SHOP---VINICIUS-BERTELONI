# Sincronizacao semanal do Elevate 4D Hub

Este repositorio verifica o site original toda segunda-feira, as 09:17 no horario de Brasilia.

Quando encontra mudancas, a automacao:

1. baixa novamente todas as paginas e arquivos internos acessiveis;
2. compara o resultado com a copia atual;
3. cria ou atualiza o Pull Request `automation/site-sync`;
4. envia o link do Pull Request pelo WhatsApp, quando as credenciais estiverem configuradas;
5. aguarda aprovacao humana. Nada e publicado automaticamente na branch `main`.

Depois que o Pull Request for revisado e incorporado com **Merge pull request**, o GitHub Pages publica a nova versao.

## Permissoes obrigatorias no GitHub

Em **Settings -> Actions -> General -> Workflow permissions**:

- selecione **Read and write permissions**;
- marque **Allow GitHub Actions to create and approve pull requests**;
- clique em **Save**.

## Segredos do WhatsApp

A notificacao usa a API oficial do WhatsApp Business/Cloud API. Ela exige uma conta configurada na Meta, um numero remetente e um modelo de mensagem aprovado.

Crie um modelo em portugues chamado, por exemplo, `atualizacao_site_disponivel`, com uma variavel no corpo:

```text
Foi encontrada uma atualizacao no site. Revise e aprove aqui: {{1}}
```

Depois, em **Settings -> Secrets and variables -> Actions -> New repository secret**, cadastre:

- `WHATSAPP_ACCESS_TOKEN`: token permanente da Cloud API;
- `WHATSAPP_PHONE_NUMBER_ID`: identificador do numero remetente;
- `WHATSAPP_TO`: telefone que recebera o aviso, com DDI e DDD, somente numeros;
- `WHATSAPP_TEMPLATE_NAME`: nome do modelo aprovado, como `atualizacao_site_disponivel`;
- `WHATSAPP_API_VERSION`: versao da Graph API habilitada no aplicativo Meta.

Os valores ficam protegidos pelo GitHub e nunca devem ser colocados diretamente nos arquivos deste repositorio publico.

## Teste manual

Abra **Actions -> Verificar atualizacoes do site original -> Run workflow**. Se nao houver mudanca, a execucao termina sem criar Pull Request. Se o WhatsApp ainda nao estiver configurado, a verificacao e o Pull Request continuam funcionando normalmente.
