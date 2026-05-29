# Rascunho da ficha da App Store - português

Status: texto preparado. Não enviar nem publicar sem aprovação de Andrei.

## Campos de metadados

| Campo | Rascunho |
|---|---|
| Nome, máximo 30 caracteres | Dspeech ATC |
| Subtítulo, máximo 30 caracteres | ATC privado em texto |
| Texto promocional, máximo 100 caracteres | Transcrição ATC no iPhone. Texto grande na cabine, offline-first, sem conta. |
| URL de suporte | BLOQUEADO - URL pública de suporte exigida antes do envio dos metadados da App Store |
| URL de marketing | BLOQUEADO - URL pública opcional de marketing ainda não aprovada |
| Palavras-chave, máximo 100 bytes | atc,pilot,cockpit,aviation,transcript,radio,flight,intercom,offline,airband,student |

## Descrição, máximo 4000 caracteres

Dspeech transforma áudio ao vivo da cabine e do ATC em texto grande e fácil de ler no iPhone, com privacidade como padrão.

Seu áudio fica no dispositivo. Dspeech foi desenhado para reconhecimento de fala local, configurações locais e uso sem conta. O alvo atual do app não inclui SDK de análise, SDK de anúncios nem caminho de rastreamento.

Por que pilotos usam:

- Ler comunicações ATC como texto grande, adequado para a cabine.
- Manter o áudio original do rádio como referência principal enquanto o texto serve como auxílio suplementar.
- Ver o selo LOCAL na tela principal.
- Ver indicadores de rota de entrada sem enviar áudio da cabine a um servidor.
- Manter configurações do filtro de voz e estado do pacote de modelo no dispositivo.

Privacidade por design:

- Não requer conta.
- No modo local, o áudio não é enviado.
- No modo local, transcrições não são enviadas.
- Não há rastreamento de localização.
- Não há rastreamento publicitário.
- O app não envia mensagens externas de suporte ou vendas.

Aviso importante de aviação:

Dspeech é um auxílio suplementar de cabine. Não é aviônica certificada, não é autoridade ATC e não substitui monitoramento de rádio, julgamento do piloto, instruções do ATC, procedimentos da aeronave ou equipamentos obrigatórios. O áudio original e as autorizações oficiais continuam sendo a referência autoritativa.

Aviso de hardware:

Dspeech não promete compatibilidade com todos os headsets, intercoms, aeronaves, rotas Bluetooth ou adaptadores com fio. Use os indicadores de rota do app e valide sua configuração antes de depender de qualquer fluxo de trabalho.

Aviso de cobrança:

O plano de produto do Dspeech usa pacotes de horas de uso em vez de uma assinatura fixa. Compras StoreKit não fazem parte deste readiness-slice e só devem ser configuradas após aprovação da implementação de cobrança.

## Notas para release manager

- Categoria principal: Navigation.
- Categoria secundária: Productivity.
- A disponibilidade por país deve seguir estritamente `docs/product/pricing-top20-aviation.md`.
- Não alegar tradução, confiabilidade certificada de cabine ou suporte de hardware validado até que implementação e evidência estejam prontas.
- Não publicar respostas de privacidade por automação; a publicação final deve ser manual no App Store Connect após aprovação de Andrei.
